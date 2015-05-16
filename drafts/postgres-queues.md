You get a page and open your laptop. Your job queue has spiked to 10,000 jobs and is continuing to grow. The bloated queue means that internal components are not getting updates that are critical to the health of the platform. You start to investigate. Activity elsewhere looks normal and jobs are being worked in a timely manner. Everything else looks normal. After close to an hour feeling around the system you notice a transaction that another team has opened for analytical purposes on one of your database followers. You promptly send it a SIGINT. The queue's backlog falls off a cliff and everything returns to normal nearly instantly.

Long running databases transactions appear to be the culprit here, but how exactly can they have such a significant impact on a database table? And so quickly no less? Furthermore, the transaction wasn't even running on the master database, but was rather ongoing on a follower.

The figure blow shows a simulation of the effect. With a relatively high rate of churn through the jobs table (roughly 50 jobs a second here), the effect can be reproduced quite quickly, and once it starts to manifest (15 minutes in), it worsens very quickly without hope of recovery (causing a queue overrun).

<figure>
  <p><img src="/assets/postgres-queues/pre-queue-count.png"></p>
  <figcaption>Oldest transaction in seconds on the left. Queue count on the right. One hour in, we're close to 60k jobs.</figcaption>
</figure>

## Why Put a Job Queue in Postgres?

Your first question may be: why put a job queue in Postgres? It may be far from the use case that databases are designed for, but storing jobs in a database allows a program to take advantage of its transactional consistency; when an operation fails and rolls back, the inject job rolls back with it. Postgres transactional isolation also keeps jobs invisible to workers until their transactions commit and are ready to be worked.

As we'll see below, there are very good reasons not to use your database as a job queue, but by making sure to observe a few key points system metrics (oldest running transaction first and foremost), an app can get a long way before getting off of this system.

## Building a Test Bench

We originally noticed this problem in production, but the first step for us to be able to check any potentials solutions that we come up with is to be able to reliably reproduce it in a controlled environment. For this purpose, we wrote the [que-degradation-test](https://github.com/brandur/que-degradation-test), which is a simple program with three processes:

* A job producer.
* A job worker.
* A "longrunner" that starts a transaction and then sits idle in it.

As hoped, the program was easily able to reproduce the problem and in a reliable way. All the charts in this article are from test data produced by it.

## Slow Lock Time

The first step into figuring out exactly what's going wrong is to find out what exactly about the long running transaction is slowing the job queue down. By looking around at a few queue metrics, we quickly find a promising candidate. During stable operation, a worker locking a job to make sure that it can be worked exclusively takes on the order of < 0.01 seconds. As we can see in the figure below though, as the oldest transaction gets older, this lock time escalates quickly until it reaches 0.1 s and above. That's probably more time than it takes to work your jobs. It makes sense conceptually too &mdash; as the difficulty to lock a job increases, workers can get through fewer of them in the same amount of time, and eventually fewer jobs are worked than are being produced.

<figure>
  <p><img src="/assets/postgres-queues/pre-lock-time.png"></p>
  <figcaption>Lock time.</figcaption>
</figure>

### Locking Algorithms

We'd originally suspected QC's relatively inefficient locking mechanism to be the culprit, and so moved our implementation over to Que. To our chagrin, we found that the problem still existed there as well, even if its better overall performance did seem to help stave it off for a little bit longer. We'll be examining Que in detail here, but it's worth nothing that both of these systems are suspectible to the same root problem.

The first step was to inspect the locking algorithm itself and make sure that there were no immediately obvious red flags that would explain the performance fallout. [Inspecting Que's source code](https://github.com/chanks/que/blob/f95aec38a48a86d1b4c82297bc5ed9c88bb600d6/lib/que/sql.rb), we see that it locks a job like so:

``` sql
WITH RECURSIVE job AS (
  SELECT (j).*, pg_try_advisory_lock((j).job_id) AS locked
  FROM (
    SELECT j
    FROM que_jobs AS j
    WHERE queue = $1::text
    AND run_at <= now()
    ORDER BY priority, run_at, job_id
    LIMIT 1
  ) AS t1
  UNION ALL (
    SELECT (j).*, pg_try_advisory_lock((j).job_id) AS locked
    FROM (
      SELECT (
        SELECT j
        FROM que_jobs AS j
        WHERE queue = $1::text
        AND run_at <= now()
        AND (priority, run_at, job_id) > (job.priority, job.run_at, job.job_id)
        ORDER BY priority, run_at, job_id
        LIMIT 1
      ) AS j
      FROM job
      WHERE NOT job.locked
      LIMIT 1
    ) AS t1
  )
)
SELECT queue, priority, run_at, job_id, job_class, args, error_count
FROM job
WHERE locked
LIMIT 1
```

This might look a little scary, but after understanding how to read a [recursive Postgres CTE](http://www.postgresql.org/docs/devel/static/queries-with.html), it an be deconstructed into a few more easily digestible components. Recursive CTEs generally take the form of `<non-recursive term> UNION [ALL] <recursive term>` where the initial non-recursive is evaluated and acts as an anchor to seed the recursive term. As noted in the Postgres documentation, the query is evaluated as follows:

1. Evaluate the non-recursive term. Place results into a temporary _working table_.
2. So long as the working table is not empty, repeat these steps:
    1. Evaluate the recursive term, substituting the contents of the working table for the recursive reference. Place the results into a temporary _intermediate table_.
    2. Replace the contents of the working table with the contents of the intermediate table and clear the intermediate table.

In the locking expression above, we can see that our non-recursive term finds the first job in the table with the highest work priority (as defined by `run_at < now()` and `priority`) and checks to see whether it can be locked with `pg_try_advisory_lock` (Que is implemented using Postgres advisory locks because they're atomic and fast). If it was locked successfully, the condition and limit outside of the CTE (`WHERE locked LIMIT 1`) stop it immediately and return that result. If the lock was unsuccessful, it recurses.

Each run of the recursive term does mostly the same thing as the non-recursive one, except that an additional predicate is added that only examines jobs of lower priority than the ones that have already been examined (`AND (priority, run_at, job_id) > (job.priority, job.run_at, job.job_id)`). By recursing continually given this stable sorting mechanism, jobs in the table are iterated one-by-one and a lock is attempted on each.

Eventually one of two conditions will be met that ends the recursion:

* A job is locked, iteration is stopped by `LIMIT` combined with the check on `locked`, and the expression returns.
* If there are no more candidates to lock, the select from `que_jobs` will come up empty, which will automatically terminate the expression.

Taking a closer look at the [jobs table DDL](https://github.com/chanks/que/blob/f95aec38a48a86d1b4c82297bc5ed9c88bb600d6/lib/que/migrations/1/up.sql#L11) we see that its primary key on (priority, run_at, job_id) should ensure that the expression above will run efficiently. We may be able to improve the locking algorithm's efficiency by introducing some random jitter so that workers run into less contention, but contention can't explain the multiple order of magnitude degradation in performance that we're seeing, so let's move on.

## Dead Tuples

By continuing to examine test data, we quickly notice another strong correlation. As the age of the oldest transaction increases, the number of dead tuples grows continually. The figure below shows how by the end of our experiment, we're approaching an incredible 100,000 dead rows.

<figure>
  <p><img src="/assets/postgres-queues/pre-dead-tuples.png"></p>
  <figcaption>Dead tuples.</figcaption>
</figure>

Automated Postgres VACUUM processes are supposed to clean these up, but upon closer inspection, we see that they can't be removed:

``` sql
=> vacuum verbose que_jobs;
INFO:  vacuuming "public.que_jobs"
INFO:  index "que_jobs_pkey" now contains 247793 row versions in 4724 pages
DETAIL:  0 index row versions were removed.
3492 index pages have been deleted, 1355 are currently reusable.
CPU 0.00s/0.02u sec elapsed 0.05 sec.
INFO:  "que_jobs": found 0 removable, 247459 nonremovable row versions in 2387 out of 4303 pages
DETAIL:  247311 dead row versions cannot be removed yet.
...
```

Notice the last line "247311 dead row versions cannot be removed yet". What this opaque Posgres error message is trying to tell is that these rows can't be removed because they're still potentially visible to another process in the system. It may seem counterintuitive that dead rows could have such serious performance implications for a live system, but they can. To understand why, we'll have to dig a little further into the Postgres MVCC model.

### The Postgres MVCC Model

To guarantee transaction isolation (that's the "I" in "ACID"), Postgres implements a [concurrency control](http://www.postgresql.org/docs/9.4/static/mvcc.html) model called MVCC (Multiversion Concurrency Control) that ensures that each ongoing SQL statement sees a consistent snapshot of data regardless of what changes may have occurred on the underlying data. By extension, that means that rows that are deleted from a Postgres database are not actually deleted immediately. Instead, they're marked as deleted so that they they're still available to any open snapshots that may still have use for them. When they're no longer needed in any snapshot, a VACUUM process will perform a pass and safely clean them up.

The flags that power MVCC are actually available as "hidden" columns on any Postgres table. Let's take a simple example where we're holding a few unworked jobs in a Que table:

```
term-A-# select xmin, xmax, job_id from que_jobs limit 5;
 xmin  | xmax | job_id
-------+------+--------
 89912 |    0 |  25865
 89913 |    0 |  25866
 89914 |    0 |  25867
 89915 |    0 |  25868
 89916 |    0 |  25869
(5 rows)
```

Every write transaction in Postgres is assigned a transaction ID (`xid`). The `xmin` column defines the minimum transaction ID for which a particular row becomes visible (i.e. the `xid` where it was created). `xmax` defines the maximum `xid` bound that the row is available. As above, for a row that's still available to any new transaction, that number is set to 0.

If we start a new transaction from a different console:

```
term-B-# start transaction isolation level serializable;
START TRANSACTION
```

Then remove one of the jobs:

```
term-A-# delete from que_jobs where job_id = 25865;
DELETE 1
```

We can see that the removed row (which is still visible from our second transaction), now has its `xmax` set:

```
term-B-# select xmin, xmax, job_id from que_jobs limit 5;
 xmin  | xmax  | job_id
-------+-------+--------
 89912 | 90505 |  25865
 89913 |     0 |  25866
 89914 |     0 |  25867
 89915 |     0 |  25868
 89916 |     0 |  25869
(5 rows)
```

### Descending the B-tree

The standard Postgres index is implemented as a [B-tree](http://en.wikipedia.org/wiki/B-tree) which is descended to find TIDs (tuple identifiers) that are stored in its leaves. These TIDs then map back to physical locations of rows within the index's table which Postgres can use to extract the full tuple.

The one key piece of information here is that an index _does not contain tuple visibility information_. To know whether a tuple is still visible to the currently run transaction, it must be extracted from the heap and have its visibility checked.

The Postgres codebase is large enough that pointing to a single place to outline this detail in the implementation is difficult, but `index_getnext` as shown below is a pretty important piece of it. Its job is to scan any type of index in a generic way and extract a tuple that matches the conditions of an incoming query. Most of the body is wrapped in a continuous look that first dips into `index_getnext_tid` which will descend the B-tree to find an appropriate TID. After one is retrieved, it's passed off to `index_fetch_heap`, which will fetch a full tuple and check its visibility against the current snapshot (contained as part of the `IndexScanDesc` type).

``` c
/* ----------------
 *		index_getnext - get the next heap tuple from a scan
 *
 * The result is the next heap tuple satisfying the scan keys and the
 * snapshot, or NULL if no more matching tuples exist.
 *
 * On success, the buffer containing the heap tup is pinned (the pin will be
 * dropped in a future index_getnext_tid, index_fetch_heap or index_endscan
 * call).
 *
 * Note: caller must check scan->xs_recheck, and perform rechecking of the
 * scan keys if required.  We do not do that here because we don't have
 * enough information to do it efficiently in the general case.
 * ----------------
 */
HeapTuple
index_getnext(IndexScanDesc scan, ScanDirection direction)
{
	HeapTuple	heapTuple;
	ItemPointer tid;

	for (;;)
	{
		if (scan->xs_continue_hot)
		{
			/*
			 * We are resuming scan of a HOT chain after having returned an
			 * earlier member.  Must still hold pin on current heap page.
			 */
			Assert(BufferIsValid(scan->xs_cbuf));
			Assert(ItemPointerGetBlockNumber(&scan->xs_ctup.t_self) ==
				   BufferGetBlockNumber(scan->xs_cbuf));
		}
		else
		{
			/* Time to fetch the next TID from the index */
			tid = index_getnext_tid(scan, direction);

			/* If we're out of index entries, we're done */
			if (tid == NULL)
				break;
		}

		/*
		 * Fetch the next (or only) visible heap tuple for this index entry.
		 * If we don't find anything, loop around and grab the next TID from
		 * the index.
		 */
		heapTuple = index_fetch_heap(scan);
		if (heapTuple != NULL)
			return heapTuple;
	}

	return NULL;				/* failure exit */
}
```

This insight along with performing some basic profiling to check it leads us to the reason our locking performance suffers so much given a long running transaction. As dead tuples continue to accumulate in the index, Postgres enters a hot loop as it continually descends the B-tree, comes up with an invisible tuple, and repeats the process again and again, coming up empty-handed every time. By the end of the experiment illustrated in the charts above, every time a worker tried to lock a job this would happen 100,000 times. Worse yet, every time a job is successfully worked a new dead tuple is left in the index, making the next job that much harder to lock.

A job queue's access pattern is particularly susceptible to this kind of degradation because all this work gets thrown out between every job that gets worked. In an attempt to minimize the amount of time that a job sits in the queue, these type of queueing systems tend to only grab one job at a time which leads to short waiting periods during optimal performance, but particularly pathologic behavior during the worse case scenario.

## But on a Follower?

It's somewhat intuitive at least how a long lived transaction on the primary could end up bloating a table and taking down a job queue, but it's a little less so on how one on a follower could have the same effect. A [number of mechanisms](http://www.postgresql.org/docs/9.4/static/hot-standby.html) exist to help mitigate the effects of query conflicts between primaries and followers, one of which is `hot_standby_feedback`. This option allows followers to report their snapshots to the primary in such a way that it will consider them when performing visibility calculations during a VACUUM. If you've ever used a Heroku Postgres database, you've used Postgres with `hot_standby_feedback` enabled.

## Solutions

### Predicate Specificity

Stated plainly, our fundamental problem here is that our index has become less useful. Even after selecting rows based on the predicates we've specified, Postgres still has to seek through thousands of dead rows before finally arriving at something that it can use.

Referencing the locking SQL above, we can see that it's the minimal constraint on only queue name and `run_at` that's causing us grief. In the degraded case, all dead rows that have already been worked will match both these conditions.

``` sql
WHERE queue = $1::text
AND run_at <= now()
```

We know that the third field in the Que table's primary key is `job_id`; what if we could modify the predicate above to take it into account as well? If we could supply a `job_id` that was even reasonably fresh, that should be enough to increase the specificity of the query enough to skip thousands of dead rows that we might have otherwise had to examine.

Because Que works jobs in order that they came into the queue, having workers re-use the identifier of the last job they worked might be a simple way to accomplish this. Here's some basic pseudocode:

```
last_job_id = nil

loop do
  # if last_job_id is nil, the extra constraint on job_id is left out of the
  # lock query
  job = lock_job(last_job_id)
  work_job(job)
  last_job_id = job.id
end
```

Let's [apply an equivalent patch to Que]() and see how it fairs. Here's oldest transaction time vs. queue count _after_ the patch:

<figure>
  <p><img src="/assets/postgres-queues/post-queue-count.png"></p>
  <figcaption>Queue count.</figcaption>
</figure>

And for comparison, here's what it looked like _before_ the patch:

<figure>
  <p><img src="/assets/postgres-queues/pre-queue-count.png"></p>
  <figcaption>Oldest transaction in seconds on the left. Queue count on the right.</figcaption>
</figure>

We can see above that the patched version of Que performs much better for much longer under the degraded conditions. It eventually hockeysticks as well, but only after maintaining a stable queue for a considerable amount of time. We found this hockeystick tendency to be partly a function of database size too; the tests above were run on a `heroku-postgresql:standard-0`, but a `heroku-postgresql:standard-7` with the patched version of Que was able to maintain near zero queue for the entire duration of the experimental run, while the unpatched version looked nearly identical to its companion on the smaller database.

#### Lock Jitter

An astute reader may have noticed that our proposed revision of the locking algorithm above introduces a new problem. If a worker dies or a transaction commits a job ID that's out of order, it's possible for all online workers to have moved onto `last_job_ids` that are all higher than one of the unworked jobs left in the queue, leaving that job in an indefinite limbo.

To account for this problem our patch to Que introduces a time-based form of locking jitter. Every so often each worker will forget their `last_job_id` and select any available job from the queue. If a long-lived transaction is ongoing, these selects without a `job_id` will be significantly more expensive, but they will be run infrequently enough that our job queue should still be able to remain stable overall.

An amended form of the new locking pseudocode might look like this:

```
last_job_id = nil
start = now()

loop do
  # lock jitter
  if now() > start + 60.seconds
    last_job_id = nil
    start = now()
  end

  job = lock_job(last_job_id)
  work_job(job)
  last_job_id = job.id
end
```

### Lock Multiple Jobs

An alternative approach to solving the same problem might be to have each worker lock more than one job at a time, which distributes the cost of taking the lock. The disadvantage to this approach is that the overall time to get a job worked may suffer because jobs can get "stuck" behind a long-running job that happened to come out ahead of them in the same batch.

### Batch Jobs to Redis

Yet another approach might be to drop your Postgres-based queues completely and instead save jobs to a `pending_jobs` table in your database. A background process could then loop through and select jobs from this table en masse and feed them out to a Redis-backed job queue like Sidekiq. This would allow your project to keep the nice database-based property of transaction consistency, but the background worker selecting jobs in bulk would keep the implementation orders of magnitude more resistant to long-lived transactions than Que or Queue Classic.

The extra hop required for the `pending_jobs` table may make this implementation a little slower than a Postgres-based queue operating under ideal conditions, but it could probably be optimized so as not to be too costly.

## Lessons Learned

Given a full understanding of problems with long-lived transactions in Postgres, a tempting (but overly simplistic) takeaway might be that Postgres isn't a good fit for a job queue. This is at least partly correct, but it's worth remembering that although a job queue may be the least optimal situation, similar problems can develop for any sufficiently hot Postgres table.

First and foremost, it's worth considering a Postgres supervisor that keeps an eye on transactions in the leader and all followers, and executes a `pg_terminate_backend` on anything that's been alive for too long. Postgres also provides a built-in [setting called `statement_timeout`](http://www.postgresql.org/docs/9.4/static/runtime-config-client.html#GUC-STATEMENT-TIMEOUT) that's worth enabling as well, but which is insufficient in itself because it can fail under a variety of conditions (like a user overriding it manually).

Finally, I'd highly encourage database use to stay within the operational boundaries of a single component. This has already been addressed elsewhere online, but the correct way for components to intercommunicate is via well-defined and safe-by-default APIs. If we hadn't shared our database with other teams who had a relatively poor understanding as to what they were running on it, this problem would have taken significantly longer to appear.

## Summary

Long lived transactions on a Postgres database can cause a variety of problems for hot tables including a job queue. Given a reasonable understanding of how Postgres' B-tree and tuple visibility logic works, we can change our implementation to improve this situation, but not eliminate it completely. For optimal results, monitor long-lived transactions within Postgres clusters and don't share databases across component or team boundaries.

Times:

* Without patch: 1430875700
* With patch: 1431038950