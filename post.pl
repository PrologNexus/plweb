:- module(post,
	  [ find_posts/3,		% +Kind:oneof([annotation,news])
					% :CheckId
					% -Ids:list(atom)
	    fresh/1,			% ?Id:atom
	    all/1,			% ?Id:atom
	    post/3,			% ?Post:or([atom,compound])
					% ?Name:atom
					% ?Value
	    post//3,			% +Options:list(nvpair)
					% +About:atom
					% +Post:compound
	    posts//3,			% +Kind:oneof([annotation,news])
					% +About:atom
					% +Ids:list(atom)
	    relevance/2,		% +Id:atom
					% -Relevance:between(0.0,1.0)
	    post_process/2,		% +Request:list, +Id:atom
	    sort_posts/2		% +Ids:list(atom), -SortedIds:list(atom)
	  ]).

/** <module> Posts

@author Wouter Beek
@tbd Type-based JS response.
     After DELETE: remove that post from DOM.
     After POST: add that post to DOM.
     After PUT: update that post in DOM.
*/

:- use_module(generics).
:- use_module(library(crypt)).
:- use_module(library(http/html_head)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_path)).
:- use_module(library(http/http_server_files)).
:- use_module(library(http/js_write)).
:- use_module(library(http/json_convert)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(pairs)).
:- use_module(library(persistency)).
:- use_module(library(pldoc/doc_html)).
:- use_module(library(uri)).
:- use_module(openid).

:- meta_predicate(find_posts(+,1,-)).

% /css
:- html_resource(css('post.css'), []).

% /js
:- html_resource(js('markitup/sets/pldoc/set.js'), [
  requires([
    js('markitup/jquery.markitup.js'),
    js('markitup/skins/markitup/style.css'),
    js('markitup/sets/pldoc/style.css')
  ])
]).

:- dynamic
	category/1.

:- persistent
	post(id:atom,
	     post:dict).

:- initialization
	db_attach('post.db', [sync(close)]).

:- op(100, xf, ?).

post_type(post{kind:oneof([annotation,news]),
	       title:string,
	       content:string,
	       meta:meta{author:atom,
			 about:any,
			 categories:list(atom),
			 importance:between(0.0,1.0),
			 time:time{posted:integer,
				   'freshness-lifetime':integer},
			 votes:votes{up:nonneg,
				     down:nonneg}}}).

%%	convert_post(+Dict0, -Dict) is det.
%
%	@error	May throw type and instantiation errors.
%	@tbd	Introduce type-testing support in library(error).

convert_post(Post0, Post) :-
	post_type(Type),
	convert_dict(Type, Post0, Post).

%%	convert_dict(+Type, +DictIn, -DictOut) is det.

convert_dict(TypeDict, Dict0, Dict) :-
	is_dict(TypeDict), !,
	dict_pairs(TypeDict, Tag, TypePairs),
	dict_values(TypePairs, Dict0, Pairs),
	dict_pairs(Dict, Tag, Pairs).
convert_dict(atom, String, Atom) :- !,
	atom_string(Atom, String).
convert_dict(oneof(Atoms), String, Atom) :-
	maplist(atom, Atoms), !,
	atom_string(Atom, String),
	must_be(oneof(Atoms), Atom).
convert_dict(float, Number, Float) :- !,
	Float is float(Number).
convert_dict(Type, Value, Value) :-
	must_be(Type, Value).

dict_values([], _, []).
dict_values([Name-Type|TP], Dict, [Name-Value|TV]) :-
	dict_value(Type, Name, Dict, Value),
	dict_values(TP, Dict, TV).

dict_value(Type?, Name, Dict, Value) :- !,
	(   get_dict(Name, Dict, Value0)
	->  (   Value0 == null
	    ->  Value = Value0
	    ;   convert_dict(Type, Value0, Value)
	    )
	;   Value = null
	).
dict_value(Type, Name, Dict, Value) :-
	get_dict(Name, Dict, Value0),
	convert_dict(Type, Value0, Value).


% /category
http:location(category, root(category), []).
:- http_handler(root(category), category_overview, [prefix]).

% Image files can be loaded from the `/img` path.
http:location(img, root(img), []).
user:file_search_path(img, document_root(img)).
:- http_handler(img(.), serve_files_in_directory(img), [prefix]).

http:location(post, root(post), []).

% PERSISTENCY PREDICATES %

retract_post(Id):-
	retract_post(Id, _).

%%	convert_post(+JSON, +Author, -Post) is det.
%
%	Convert a post object into its Prolog equivalent.

convert_post(Post0, Author, Post) :-
	get_time(Now),
	Post1 = Post0.put(meta.author, Author)
		     .put(meta.time.posted, Now),
	convert_post(Post1, Post).


%%	post_process(+Request, ?Kind) is det.
%
%	HTTP handler that implements a REST interface for postings.
%
%	@arg	Kind is the type of post, and is one of =news= or
%		=annotation=.

post_process(Request, Kind) :-
	must_be(oneof([news,annotation]), Kind),
	request_to_id(Request, Kind, Id),
	memberchk(method(Method), Request),
	(   site_user_logged_in(User)
	->  true
	;   User = anonymous
	),
	post_process(Method, Request, Kind, User, Id).

%%	post_process(+Method, +Request, +Kind, +Id, +User) is det.
%
%	Implement the REST replies.

% DELETE
post_process(delete, Request, Kind, User, Id) :-
	post_authorized(Request, User, Kind),
	post(Id, author, Author), !,
	(   Author == User
	->  retract_post(Id),
	    throw(http_reply(no_content))	% 204
	;   memberchk(path(Path), Request),
	    throw(http_reply(forbidden(Path)))	% 403
	).
post_process(delete, Request, _, _, _) :-
	http_404([], Request).

% GET
post_process(get, _, _, _, Id):-
	post(Id, Post), !,
	reply_json(Post).
post_process(get, Request, _, _, _):-
	http_404([], Request).

% POST
post_process(post, Request, Kind, User, _):-
	post_authorized(Request, User, Kind),
	catch(( http_read_json_dict(Request, Post0),
		convert_post(Post0, User, NewPost),
		uuid(Id),
		assert_post(Id, NewPost)
	      ),
	      E,
	      throw(http_reply(bad_request(E)))),
	memberchk(path(Path), Request),
	atom_concat(Path, Id, NewLocation),
	format('Location: ~w~n', [NewLocation]),
	reply_json(_{created:Id, href:NewLocation},
		   [status(201)]).

% PUT
post_process(put, Request, Kind, User, Id):-
	post_authorized(Request, User, Kind),
	catch(( http_read_json_dict(Request, Post0),
		convert_post(Post0, User, NewPost)
	      ),
	      E,
	      throw(http_reply(bad_request(E)))),
	(   post(Id, author, Author)
	->  (   Author == User
	    ->  retract_post(Id),
		assert_post(Id, NewPost),
		throw(http_reply(no_content))
	    ;   memberchk(path(Path), Request),
		throw(http_reply(forbidden(Path)))
	    )
	;   http_404([], Request)
	).


%%	post_authorized(+Request, +User, +Kind) is det.
%
%	@throws	http_reply(forbidden(Path)) if the user is not allowed
%		to post.
%	@tbd	If the user is =anonymous=, we should reply 401 instead
%		of 403, but we want OpenID login

post_authorized(_Request, User, Kind) :-
	post_granted(User, Kind), !.
post_authorized(Request, _User, _Kind) :-
	memberchk(path(Path), Request),
	throw(http_reply(forbidden(Path))).

post_granted(User, Kind) :-
	site_user_property(User, granted(Kind)).
post_granted(User, annotation) :-
	User \== anonymous.


% ACCESSOR PREDICATES %

%!	post(+Post:dict, +Name:atom, -Value) is semidet.
%!	post(+Post:dict, -Name:atom, -Value) is nondet.
%
%	True if Post have Value for the given attribute.
%
%	@arg Post is

post(Post, Name, Value):-
	nonvar(Name), !,
	post1(Post, Name, Value),
	Value \== null, !.
post(Post, Name, Value):-
	post1(Post, Name, Value).

post1(Name, Id, Value) :-
	atom(Id), !,
	post(Id, Post),
	post1(Post, Name, Value).
post1(about, Post, About) :-
	About = Post.meta.about.
post1(author, Post, Author) :-
	Author = Post.meta.author.
post1(categories, Post, Categories) :-
	Categories = Post.meta.categories.
post1(content, Post, Content) :-
	Content = Post.content.
post1('freshness-lifetime', Post, FreshnessLifetime ) :-
	FreshnessLifetime = Post.meta.time.'freshness-lifetime'.
post1(id, Post, Id) :-
	post(Id, Post).
post1(importance, Post, Importance) :-
	Importance = Post.meta.importance.
post1(kind, Post, Kind) :-
	Kind = Post.kind.
post1(meta, Post, Meta) :-
	Meta = Post.meta.
post1(posted, Post, Posted) :-
	Posted = Post.meta.time.posted.
post1(time, Post, Time):-
	Time = Post.meta.time.
post1(title, Post, Title) :-
	Title = Post.title.
post1(votes, Post, Up-Down) :-
	_{up:Up, down:Down} :< Post.meta.votes.
post1(votes_down, Post, Down) :-
	Down = Post.meta.votes.down.
post1(Post, votes_up, Up) :-
	Up = Post.meta.votes.up.


% SINGLE POST %

%! post(+Options:list(nvpair), +About:atom, +Id:atom)// is det.
% Generates a post, based on the given compound term.
%
% The following options are supported (first parameter of `Post`):
%   * orientation(+Orientation:oneof([left,right]))
%     Orientation of the post.
%     This is used in binary conversations
%      to show the different conversation parties.
%   * standalone(+Standalone:boolean)
%     Whether this post is part of multiple posts or not.

post(O1, About, Id) -->
  { post(Id, kind, Kind),
    (	option(orientation(Orient), O1),
	Orient \== none
    ->	Extra = [ style('float:'+Orient+';') ]
    ;	Extra = []
    )
  },

  html(article([ class([post,Kind]),
		 id(Id)
	       | Extra
	       ],
	       [ \post_header(O1, Id),
		 \post_section(Id),
		 \edit_remove_post(Id)
	       ])),

  % Standalone option.
  (
    {option(standalone(true), O1, true)}
  ->
    html_requires(css('post.css')),
    (
      {site_user_logged_in(_)}
    ->
      html(\write_post_js(Kind, About))
    ;
      login_post(Kind)
    )
  ;
    []
  ).

post_categories(Id) -->
  {
    post(Id, categories, Categories),
    nonvar(Categories)
  }, !,
  post_categories1(Categories).
post_categories(_) --> [].

post_categories1([]) --> !, [].
post_categories1(L) -->
  html([' under ',span(class=categories, \post_categories2(L))]).

post_categories2([]) --> !, [].
post_categories2([H|T]) -->
  post_category(H),
  post_categories2(T).

post_category(Category) -->
  {
    category_exists(Category),
    http_absolute_location(category(Category), Link, [])
  },
  html(a([class='post-category',href=Link],Category)).

%! post_header(+Options:list(nvpair), +Id:atom)// is det.
% When the post appears in isolation (option =|standalone(true)|=),
%  the title is not displayed.

post_header(O1, Id) -->
  html(
    header([], [
      \post_title(O1, Id),
      \post_metadata(Id),
      span(class='post-links-and-votes', [
        \post_votes(Id),
        \html_receive(edit_remove(Id))
      ])
    ])
  ).

post_metadata(Id) -->
  {post(Id, kind, Kind)},
  post_metadata(Kind, Id).

post_metadata(annotation, Id) -->
  {post(Id, author, Author)},
  html(
    span(class='post-meta', [
      \user_profile_link(Author),
      ' said (',
      \post_time(Id),
      '):'
    ])
  ).
post_metadata(news, Id) -->
  {post(Id, author, Author)},
  html(
    span(class='post-meta', [
      'By ',
      \user_profile_link(Author),
      %\post_categories(Id),
      ' at ',
      \post_time(Id)
    ])
  ).

post_section(Id) -->
  {
    post(Id, author, Author),
    post(Id, content, Content),
    atom_codes(Content, Codes),
    wiki_file_codes_to_dom(Codes, /, DOM1),
    clean_dom(DOM1, DOM2)
  },
  html(
    section([], [
      \author_image(Author),
      div(class='read-post', DOM2)
    ])
  ).

post_time(Id) -->
  {post(Id, posted, Posted)},
  html(\dateTime(Posted)).

post_title(O1, Id) -->
  {
    option(standalone(false), O1, true),
    post(Id, title, Title),
    nonvar(Title), !,
    post(Id, kind, Kind),
    Spec =.. [Kind,Id],
    http_absolute_location(Spec, Link, [])
  },
  html(h2(class='post-title',a(href=Link,Title))).
post_title(_, _) --> [].

post_votes(Id) -->
  {
    post(Id, votes_down, Down),
    format(atom(AltDown), '~d downvotes', [Down]),
    post(Id, votes_up, Up),
    format(atom(AltUp), '~d upvotes', [Up]),
    post(Id, votes, Amount)
  },
  html([
    a([class='post-vote-up',href=''],
      img([alt=AltUp,src='/icons/vote_up.gif',title=Up], [])
    ),
    ' ',
    span(class='post-vote-amount', Amount),
    ' ',
    a([class='post-vote-down',href=''],
      img([alt=AltDown,src='/icons/vote_down.gif',title=Down], [])
    )
  ]).



% MULTIPLE POSTS %

posts(Kind, About, Ids1) -->
  {
    atomic_list_concat([Kind,component], '-', Class),
    sort_posts(Ids1, votes, Ids2)
  },
  html([
    \html_requires(css('post.css')),
    div(class=[posts,Class], \posts(Kind, About, none, Ids2)),
    \add_post(Kind, About)
  ]).

posts(_Kind, _About, _Orient, []) --> [].
posts(Kind, About, Orient1, [Id|Ids]) -->
  post([orientation(Orient1),standalone(false)], About, Id),
  {switch_orientation(Orient1, Orient2)},
  posts(Kind, About, Orient2, Ids).

switch_orientation(left,  right).
switch_orientation(right, left).
switch_orientation(none,  none).


%%	add_post(+Kind, +About)//
%
%	Emit HTML that allows for adding a new post

add_post(Kind, About) -->
	{ site_user_logged_in(User),
	  post_granted(User, Kind)
	}, !,
	html(div(id='add-post',
		 [ \add_post_link,
		   form([id='add-post-content',style='display:none;'],
			[ \add_post_title(Kind),
			  \add_post_importance(Kind),
			  \add_post_freshnesslifetime(Kind),
			  \add_post_content
			]),
		   \submit_post_links,
		   \write_post_js(Kind, About)
		 ])).
add_post(Kind, _) -->
	login_post(Kind).

add_post_content -->
  html(textarea([class=markItUp], [])).

add_post_freshnesslifetime(news) --> !,
  % Freshness lifetime is represented in seconds.
  % 1 day is appoximately 86.400 seconds.
  html([
    label([], 'Freshness lifetime: '),
    select(class='freshness-lifetime', [
      option(value=31536000, 'Very long'),                % One year (almost 'sticky')
      option(value=2678400, 'Long'),                      % One month
      option([selected=selected,value=604800], 'Normal'), % One week
      option(value=86400, 'Short'),                       % One day
      option(value=3600, 'Very short')                    % One hour
    ]),
    br([])
  ]).
add_post_freshnesslifetime(_) --> [].

add_post_importance(news) --> !,
  html([
    label([], 'Importance: '),
    select(class=importance, [
      option(value=1.00, 'Very high'),
      option(value=0.75, 'High'),
      option([selected=selected,value=0.50], 'Normal'),
      option(value=0.25, 'Low'),
      option(value=0.00, 'Very low')
    ])
  ]).
add_post_importance(_) --> [].

add_post_link -->
  html(a([id='add-post-link',href=''], 'Add post')).

add_post_title(news) --> !,
  html([
    label([], 'Title: '),
    input([class=title,size=70,type=text], []),
    br([])
  ]).
add_post_title(_) --> [].

submit_post_links -->
  html(
    div([id='add-post-links',style='display:none;'], [
      a([id='add-post-submit',href=''], 'Add comment'),
      a([id='add-post-cancel',href=''], 'Cancel')
    ])
  ).



% EDIT/REMOVE POST %

edit_post(Id) -->
  {
    post(Id, author, Author),
    site_user_logged_in(Author), !,
    post(Id, kind, Kind)
  },
  html([
    form([class='edit-post-content',style='display:none;'], [
      % @tbd Set title value.
      \add_post_title(Kind),
      % @tbd Set importance value.
      \add_post_importance(Kind),
      % @tbd Set freshness lifetime value.
      \add_post_freshnesslifetime(Kind),
      \edit_post_content(Id)
    ]),
    \save_post_links
  ]).
edit_post(_) --> [].

edit_post_content(Id) -->
  {post(Id, content, Content)},
  html(textarea([class=markItUp,cols=120,rows=10,style='display:none;'], Content)).

edit_remove_post(Id) -->
  {
    post(Id, author, Author),
    site_user_logged_in(Author), !
  },
  html([
    \html_post(edit_remove(Id), \edit_remove_post_link),
    \edit_post(Id)
  ]).
edit_remove_post(_) --> [].

edit_remove_post_link -->
  html([
    ' ',
    a([class='edit-post-link',href=''], 'Edit'),
    '/',
    a([class='remove-post-link',href=''], 'Delete')
  ]).

save_post_links -->
  html(
    div([class='edit-post-links',style='display:none;'], [
      a([class='edit-post-submit',href=''], 'Edit comment'),
      a([class='edit-post-cancel',href=''], 'Cancel')
    ])
  ).



% HELPERS %

%! age(+Id:atom, -Age:nonneg) is det.

age(Id, Age):-
  post(Id, posted, Posted),
  get_time(Now),
  Age is Now - Posted.

%! author_image(+User:atom)// is det.

author_image(User) -->
  {
    site_user_property(User, name(Name)),
    format(atom(Alt), 'Picture of user ~w.', [Name]),

    % @see Documentation
    %      https://en.gravatar.com/site/implement/hash/
    site_user_property(User, email(Email)),
    downcase_atom(Email, CanonicalEmail),
    md5(CanonicalEmail, Hash),

    % @see Documentation
    %      https://en.gravatar.com/site/implement/images/
    % @see Example
    %      http://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50
    uri_path([avatar,Hash], Path),
    uri_components(URL, uri_components(http, 'www.gravatar.com', Path, _, _)),

    % Also provide a link to the user profile.
    http_link_to_id(view_profile, [user(User)], Link)
  },
  html(a(href=Link,img([alt=Alt,class='post-avatar',src=URL,title=Name]))).

category_exists(Category):-
  category(Category), !.
category_exists(Category):-
  assert(category(Category)).

category_overview(Request):-
  memberchk(path(Path), Request),
  atom_concat('/category/', Category, Path),
  once(category(Category)), !,
  format(atom(Title), 'Category -- ~a', [Category]),
  reply_html_page(wiki, title(Title), ['Category ',Category,' TODO']).

dateTime(TimeStamp) -->
  % Alternative format: `%A %d %B %Y`.
  {format_time(atom(Date), '%Y-%m-%dT%H:%M:%S', TimeStamp)},
  html(span([class(date),title(TimeStamp)], Date)).

%! find_posts(
%!  +Kind:oneof([annotation,news]),
%!  :CheckId,
%!  -Ids:list(atom)
%! ) is det.

find_posts(Kind, CheckId, Ids):-
  findall(
    Id,
    (
      post(Id, Post),
      post(Post, kind, Kind),
      call(CheckId, Id)
    ),
    Ids
  ).

%! fresh(+Id:atom) is semidet.
%! fresh(-Id:atom) is nondet

fresh(Id):-
  post(Id, 'freshness-lifetime', FreshnessLifetime),
  nonvar(FreshnessLifetime), !,
  age(Id, Age),
  Age < FreshnessLifetime.
fresh(_).

%! all(+Id:atom) is det.
%
%  News filter, retuning all objects

all(_).

%! relevance(+Id:atom, -Relevance:between(0.0,1.0)) is det.
% - If `Importance` is higher, then the dropoff of `Relevance` is flatter.
% - `Relevance` is 0.0 if `FreshnessLifetime =< Age`.
% - `Relevance` is 1.0 if `Age == 0`.

relevance(Id, Relevance):-
  fresh(Id),
  post(Id, importance, Importance),
  nonvar(Importance),
  post(Id, 'freshness-lifetime', FreshnessLifetime),
  nonvar(FreshnessLifetime), !,
  age(Id, Age),
  Relevance is Importance * (1 - Age / FreshnessLifetime).
relevance(_, 0.0).

sort_posts(Ids, SortedIds):-
  sort_posts(Ids, posted, SortedIds).

sort_posts(Ids, Property, SortedIds):-
  findall(
    Value-Id,
    (
      member(Id, Ids),
      post(Id, Property, Value)
    ),
    Temp1
  ),
  keysort(Temp1, Temp2),
  reverse(Temp2, Temp3),
  pairs_values(Temp3, SortedIds).

%! stale(+Id:atom) is semidet.
%! stale(?Id:atom) is nondet

stale(Id):-
  \+ fresh(Id).



% SCRIPT %

login_post(Kind) -->
	{ site_user_logged_in(_), !,
	  http_link_to_id(register, [for(Kind)], HREF)
	},
	html({|html(HREF, Kind)||
	      <div class="post-login">
	      <a href="HREF">request permission</a> to add a new
	      <span>Kind</span> post.
	      </div>
	     |}).
login_post(Kind) -->
	html(div(class='post-login',
		 [b(\login_link),' to add a new ',Kind,' post.'])).

% We assume the user is logged in once we get here.
write_post_js(Kind, About) -->
  {
    site_user_logged_in(Author),
    Spec =.. [Kind,'.'],
    http_absolute_uri(Spec, URL)
  },
  html([
    \html_requires(js('markitup/sets/pldoc/set.js')),
    \js_script({|javascript(Kind,URL,Author,About)||
      function http_post(url, updatePosted, form, method) {
        var down = parseInt(form.siblings("header").find(".post-vote-down").children("img").attr("title"));
        if (isNaN(down)) {down = 0;}

        var up = parseInt(form.siblings("header").find(".post-vote-up").children("img").attr("title"));
        if (isNaN(up)) {up = 0;}

        var title1, title2;
        title1 = form.find(".title").val();
        if (title1 === undefined) { title2 = null; } else { title2 = title1; }

        var posted;
        if (updatePosted) {
          posted = Math.round(Date.now()/1000);
        } else {
          var header = form.siblings("header");
          var date = header.find(".date");
          var title = date.attr("title");
          posted = parseInt(title);
        }

        $.ajax(
          url,
          {
            "contentType": "application/json; charset=utf-8",
            "data": JSON.stringify({
              "content": form.find(".markItUpEditor").val(),
              "kind": Kind,
              "meta": {
                "author": Author,
                "about": About,
                "categories": [Kind],
                "importance": parseFloat(form.find(".importance").val()),
                "time": {
                  "freshness-lifetime": parseInt(form.find(".freshness-lifetime").val(), 10),
                  "posted": posted,
                  "type": "time"
                },
                "type": "meta",
                "votes": {
                  "down": down,
                  "type": "votes",
                  "up": up
                }
              },
              "title": title2,
              "type": "post"
            }),
            "dataType": "json",
            "success": function() {location.reload();},
            "type": method
          }
        );
      }
      $(document).ready(function() {
        // Clicking this removes the UI for entering a new post.
        $("#add-post-cancel").click(function(e) {
          e.preventDefault();
          $("#add-post-links").css("display","none");
          $("#add-post-content").css("display","none");
          $("#add-post-link").css("display","block");
        });

        // Clicking this brings up the UI for entering a new post.
        $("#add-post-link").click(function(e) {
          e.preventDefault();
          $(this).css("display","none");
          $("#add-post-content").css("display","block");
          $("#add-post-links").css("display","block");
        });

        // Clicking this submits the current content as a new post.
        $("#add-post-submit").click(function(e) {
          e.preventDefault();
          http_post(
            URL,
            true,
            $(this).parent().siblings("#add-post-content"),
            "POST"
          );
        });

        // Clicking this removes the UI for editing an existing post.
        $(".edit-post-cancel").click(function(e) {
          e.preventDefault();
          var article = $(this).closest("article");
          article.children(".edit-post-links").css("display","none");
          article.children("form").css("display","none");
          article.children("header").css("display","block");
          article.children("section").css("display","block");
        });

        // Clicking this brings up the UI for editing an existing post.
        // Notice that this first hides the readable content element,
        //  and then shows the writable content element.
        $(".edit-post-link").click(function(e) {
          e.preventDefault();
          var article = $(this).closest("article");
          article.children("header").css("display","none");
          article.children("section").css("display","none");
          article.children("form").css("display","block");
          article.find("textarea").css("display","block");
          article.children(".edit-post-links").css("display","block");
        });

        // Clicking this submits the current changes to a post.
        $(".edit-post-submit").click(function(e) {
          e.preventDefault();
          var id = $(this).closest(".post").attr("id");
          http_post(
            URL+id,
            true,
            $(this).closest(".edit-post-links").siblings(".edit-post-content"),
            "PUT"
          );
        });

        // Mark-it-up support for entering post content.
        $(".markItUp").markItUp(pldoc_settings);

        // Clicking this removes an existing post.
        $(".remove-post-link").click(function(e) {
          e.preventDefault();
          var id = $(this).parents(".post").attr("id");
          $.ajax(
            URL+id,
            {
              "contentType": "application/json; charset=utf-8",
              "dataType": "json",
              "success": function() {location.reload();},
              "type": "DELETE"
            }
          );
        });

        // Clicking this decreases the number of votes by one.
        $(".post-vote-down").click(function(e) {
          e.preventDefault();
          $(this).children("img").attr(
            "title",
            parseInt($(this).children("img").attr("title")) + 1
          );
          http_post(
            URL+$(this).parents(".post").attr("id"),
            false,
            $(this).closest("header").siblings("form"),
            "PUT"
          );
        });

        // Clicking this increases the number of votes by one.
        $(".post-vote-up").click(function(e) {
          e.preventDefault();
          $(this).children("img").attr(
            "title",
            parseInt($(this).children("img").attr("title")) + 1
          );
          http_post(
            URL+$(this).parents(".post").attr("id"),
            false,
            $(this).closest("header").siblings("form"),
            "PUT"
          );
        });
      });
    |})
  ]).

