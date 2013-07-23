Today marks the beta release of [OAuth for the Heroku Platform
API](https://blog.heroku.com/archives/2013/7/22/oauth-for-platform-api-in-public-beta),
a move which we consider an important step forward in improving our story
around empowering users to develop applications against the API by providing a
simple and powerful authentication framework that's consistent with other
providers across the web.

One interesting discussion that developed while we were building this out was
around OAuth scoping, the mechanism that allows OAuth clients to tell an
authorization server what permissions they'll need on resources they're
accessing. I thought this might be a good opportunity to talk a little about
OAuth scoping, our design considerations, how its implemented elsewhere on the
web, and what the spec has to say about it.

## The Spec

[RFC 6749](http://tools.ietf.org/html/rfc6749#section-3.3) describes how scope
should be implemented according to the proposed OAuth 2 standard. I've tried to
summarize the points presented in the document:

* Scope is specified on either the authorization or token endpoints using the
  parameter `scope`.
* Scope is expressed as a set of case-sensitive and space-delimited strings.
* The authorization server may override the scope request, in this case it must
  include `scope` in its response to inform a client of their actual scope.
* When a scope is not specified, the server may either fallback to a
  well-documented default, or fail the request.

The spec describes the format that a scope should have and ow the server should
handle it, but is open-ended in respect to what strings in a scope should
actually look like. This decision allows providers to define their own strings,
and gives them enough flexibility to ensure that OAuth 2 scoping is a good fit
for accessing a wide variety of different resources.

## From Around the Web

The open-ended spec has resulted in a number of creative implementations across
the web, with no two being exactly alike. I've compiled a few examples to
demonstrate the range of ideas out there.

### App.net

App.net allows developers to define a basic set of scopes in snake_case. This
is about as close to a standard scoping implementation as you can get.

    basic stream update_profile

http://developers.app.net/docs/authentication/#scopes

### Facebook

Facebook deviates from spec a bit by suggesting that scope strings be
comma-delimited. The two other interesting characteristics of Facebook scopes
are that more specific strings are namespaced under their broader category
(e.g. `user_actions.video`), and that some strings are dynamic (e.g.
`APP_NAMESPACE` scopes to a particular app in `user_actions:APP_NAMESPACE`).
Facebook also offers a very extensive variety of available scopes so that apps
can be very precise about what powers they'll require.

    email,read_stream,user_actions.video,user_actions:APP_NAMESPACE

https://developers.facebook.com/docs/reference/login/#permissions

### GitHub

GitHub provides a concise set of scopes with some namespacing using the colon
character. For example, `user:email` is a subset of the permissions allowed by
`user`.

```
gist repo user user:email
```

Another interesting innovation here is that for any API requests, GitHub passes
back the reponse headers `X-OAuth-Scopes` and `X-Accepted-OAuth-Scopes` to
indicate to the user what scope strings their token has, and what strings this
endpoint will accept. This makes their APIs self-documenting in that it gives
users an easy alternative to looking up documentation when designating scope.

http://developer.github.com/v3/oauth/#scopes

### Google

Google mandates that scopes should start with the `openid` string, then include
either or both of `email` and `profile`. From there, scope is extended across
Google's flourishing ecosystem by defining other strings as extensible URIs.

    openid profile email https://www.googleapis.com/auth/drive.file

https://developers.google.com/accounts/docs/OAuth2Login

### Instagram

Another fairly simple implementation, with the notable use of plus signs as
delimitation rather than spaces.

    likes+comments

http://instagram.com/developer/authentication

### LinkedIn

LinkedIn reserves the underscore to separate types of resources from the
read/write permissions to that type, with an `r` specifying read privileges and
`w` write.

    r_basicprofile r_emailaddress rw_groups w_messages

https://developer.linkedin.com/documents/authentication#granting

### Salesforce

Salesforce requires a particular scope string for the privilege of being
granted a refresh token.

    api refresh_token web

http://help.salesforce.com/help/doc/en/remoteaccess_oauth_scopes.htm

### Shopify

Shopify also mixes read and write permissions into scope strings. Their system
is fairly intuitive in that `write_` also implies `read_` permission, so that
developers don't need to specify both.

    read_customers write_script_tags, write_shipping

http://docs.shopify.com/api/tutorials/oauth

### Windows Live ID

Defines scope strings that are prefixed with `wl.` (for Windows Live);
presumably so that scopes are unique across Microsoft's entire product space.

    wl.basic wl.offline_access wl.contacts_photos

http://msdn.microsoft.com/en-us/library/live/hh243646.aspx

## Heroku

The end product for Heroku OAuth scope was shaped by a few major
product-oriented design goals:

* The set of scope strings should be minimal so that we still have the power to
  evolve scoping as we continue to build out our product. Even if we completely
  redesign our scope strings, all the old strings should be general enough to
  easily map to the new system. Adding things is easy, but deprecating is hard.
* Some app resources are sensitive enough that even if a scope grants almost
  universal permission to manage an app, they still need to be protected. A
  good example of this are an app's config vars, which contain secrets like
  database connection strings. The scoping system must take this into account.
* We should provide a very minimal scope that provides basic user information
  and nothing else. This is useful in systems that will use OAuth to identify a
  user and little else like [Heroku Discussion](https://discussion.heroku.com).

Taking these goals into account, along with the spec and the web's other
implementations, we came up with a starting point for our scope system which is
what we released today:

* `identity`: Allows access to `GET /account` for basic user info, but nothing
  else.
* `read`: Read access to all a user's apps and their subresources, except for
  protected subresources like config vars and releases.
* `write`: Write access to apps and unprotected subresources. Superset of
  `read`.
* `read-protected`: Read including protected subresources. Superset of `read`.
* `write-protected`: Write including protected subresources. Superset of
  `read-protected` and `write`.
* `global`: Global access encompassing all other scope.

These strings all map to more a much more granular set of permissions in the
backend, which will allow us to continue evolving the public interface as need
be.

Like a few other providers, we also elected for self-documenting API endpoints
that help developers along by specifying their accepted scope strings as
response headers:

```
Oauth-Scope: global
Oauth-Scope-Accepted: global read read-protected write write-protected
```