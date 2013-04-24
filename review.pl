/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2013, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(pack_review,
	  [ pack_rating_votes/3,	% +Pack, -Rating, -Votes
	    pack_comment_count/2,	% +Pack, -CommentCount
	    pack_reviews//1,		% +Pack
	    show_pack_rating//1,		% +Pack
	    show_pack_rating//5		% +Pack, +Rating, +Votes, +Comment, +Opts
	  ]).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_openid)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/html_write)).
:- use_module(library(http/html_head)).
:- use_module(library(persistency)).
:- use_module(library(aggregate)).
:- use_module(library(record)).

:- use_module(markitup).
:- use_module(rating).
:- use_module(openid).
:- use_module(wiki).

:- http_handler(root(pack/review),        pack_review,        []).
:- http_handler(root(pack/review/submit), pack_submit_review, []).
:- http_handler(root(pack/review/rating), pack_rating,        []).

/** <module> Handle rating and reviewing of packages
*/

		 /*******************************
		 *	       DATA		*
		 *******************************/

:- persistent
	review(pack:atom,
	       openid:atom,
	       time:number,
	       rating:integer,
	       comment:atom).

:- db_attach('reviews.db', []).


		 /*******************************
		 *	     INTERFACE		*
		 *******************************/

%%	pack_review(+Request)
%
%	HTTP handler to review a pack.

pack_review(Request) :-
	site_user(Request, OpenId),
	http_parameters(Request,
			[ p(Pack, [])
			]),
	http_link_to_id(pack_submit_review, [], Action),
	reply_html_page(
	    wiki,
	    title('Review pack ~w'-[Pack]),
	    [ h1('Review pack ~w'-[Pack]),
	      \explain(Pack, OpenId),
	      \html_requires(css('pack.css')),
	      form([ class(review), action(Action) ],
		   [ input([type(hidden), name(p), value(Pack)]),
		     table([ \reviewer(Request, OpenId),
			     \rating(Pack, OpenId),
			     \comment(Pack, OpenId),
			     tr(td([colspan(2), align(right)],
				   input([ type(submit),
					   value('Submit review')
					 ])))
			   ])
		   ])
	    ]).


explain(Pack, OpenId) -->
	{ site_user_property(OpenId, name(Name))
	},
	html([ p([ 'Dear ', Name, ', you requested to review pack ', b(Pack), '. ',
		   'The text field uses PlDoc wiki format, which is a ',
		   'superset of Markdown.  You can use the two ',
		   'left-most icons to open and close a preview window.'
		 ]),
	       p([ 'Any user can have at most one review per pack.  Trying ',
		   'to submit a new review will return the old review and ',
		   'allow you to update your opinion.'
		 ])
	     ]).

%%	reviewer(+Request, +OpenID)// is det.
%
%	Present details about the reviewer

reviewer(Request, OpenId) -->
	{ site_user_property(OpenId, name(Name)),
	  site_user_property(OpenId, email(Email)),
	  option(request_uri(RequestURI), Request),
	  http_link_to_id(create_profile, [return(RequestURI)], UpdateURL),
	  Update = a([class(update), href(UpdateURL)], update)
	}, !,
	html([ tr([th('Name:'),   td([ input([ name(name),
					       value(Name),
					       disabled(disabled)
					     ]),
				       Update
				     ])]),
	       tr([th('E-Mail:'), td([ input([ name(email),
					       value(Email),
					       disabled(disabled)
					     ]),
				       Update
				     ])])
	     ]).


rating(Pack, OpenId) -->
	{ http_link_to_id(pack_rating, [], HREF),
	  (   review(Pack, OpenId, _, Rating0, _),
	      Rating0 > 0
	  ->  Extra = [data_average(Rating0)]
	  ;   Extra = [],
	      Rating0 = 0
	  )
	},
	html(tr([ th('Your rating for ~w:'-[Pack]),
		  td( [ input([type(hidden), name(rating), value(Rating0)]),
			\rate([ on_rating(HREF),
				data_id(Pack),
				set_field(rating),
				rate_max(5),
				step(true),
				type(big),
				can_rate_again(true)
			      | Extra
			      ])
		      ])
		])).


%%	pack_rating(+Request)
%
%	Handle the actual rating

pack_rating(Request) :-
	http_parameters(Request,
			[ idBox(IdBox, []),
			  rate(Rate, [number])
			], []),
	debug(rating, 'Got idBox = ~q, Rate = ~q', [IdBox,Rate]),
	format('Content-type: text/plain\n\n'),
	format('true\n').


comment(Pack, OpenId) -->
	{ (   review(Pack, OpenId, _, _, Comment)
	  ->  Extra = [value(Comment)]
	  ;   Extra = []
	  )
	},
	html(tr(td(colspan(2),
		   \markitup([ id(comment),
			       markup(pldoc),
			       cold(60),
			       rows(10)
			     | Extra
			     ])))).


%%	pack_submit_review(+Request)
%
%	Handle a pack review submission

pack_submit_review(Request) :-
	openid_user(Request, OpenID, []),
	http_parameters(Request,
			[ p(Pack, []),
			  rating(Rating, [number]),
			  comment(Comment, [optional(true), default('')])
			]),
	reply_html_page(
	    wiki,
	    title('Thanks for your review of ~w'-[Pack]),
	    [ \update_review(Pack, OpenID, Rating, Comment)
	    ]).


%%	update_review(+Pack, +OpenID, +Rating, +Comment)// is det.
%
%	Assert/update a review about a pack.

update_review(Pack, OpenID, Rating, Comment) -->
	{ review(Pack, OpenID, _Time, Rating, Comment) }, !,
	html(h4(class(wiki), 'No changes, showing your existing comment')),
	show_review(Pack, OpenID).
update_review(Pack, OpenID, Rating, Comment) -->
	{ review(Pack, OpenID, _Time, _Rating, _Comment), !,
	  retractall_review(Pack, OpenID, _, _, _),
	  get_time(Time),
	  assert_review(Pack, OpenID, Time, Rating, Comment)
	},
	html(h4(class(wiki), 'Updated your comments for pack ~w'-[Pack])),
	show_review(Pack, OpenID).
update_review(Pack, OpenID, Rating, Comment) -->
	{ get_time(Time),
	  assert_review(Pack, OpenID, Time, Rating, Comment)
	},
	html(h4(class(wiki), 'Added comment for pack ~w'-[Pack])),
	show_review(Pack, OpenID).


		 /*******************************
		 *	   SHOW RESULTS		*
		 *******************************/

%%	pack_reviews(Pack)// is det.
%
%	Show reviews for Pack

pack_reviews(Pack) -->
	html(h2(class(wiki), 'Reviews')),
	show_reviews(Pack).

show_reviews(Pack) -->
	{ \+ review(Pack, _, _, _, _), !,
	  http_link_to_id(pack_review, [p(Pack)], HREF)
	},
	html([ p([ 'No reviews.  ',
		   a(href(HREF), 'Create'), ' the first review!.'
		 ])
	     ]).
show_reviews(Pack) -->
	{ findall(review(Pack, OpenID, Time, Rating, Comment),
		  ( review(Pack, OpenID, Time, Rating, Comment),
		    Comment \== ''
		  ),
		  Reviews),
	  length(Reviews, Count),
	  sort_reviews(time, Reviews, Sorted),
	  http_link_to_id(pack_review, [p(Pack)], HREF)
	},
	html([ p([ \showing_reviews(Count),
		   'Click ', a(href(HREF), 'here'), ' to add a rating or ',
		   'create a new review'
		 ])
	     ]),
	list_reviews(Sorted),
	html_receive(rating_scripts).

showing_reviews(Count) -->
	{ Count >= 2 },
	html([ 'Showing ~D reviews, '-[Count],
	       'sorted by date entered, last review first. '
	     ]).
showing_reviews(_) --> [].


list_reviews([]) --> [].
list_reviews([H|T]) --> list_review(H), list_reviews(T).

list_review(Review) -->
	{ review_name(Review, Pack),
	  review_openid(Review, OpenID),
	  review_time(Review, Time),
	  review_rating(Review, Rating),
	  review_comment(Review, Comment)
	},
	html([ div(class(review),
		   [ div(class(rating),   \show_rating_value(Pack, Rating, [])),
		     div(class(comment),  \show_comment(Comment)),
		     div(class(reviewer), \show_reviewer(OpenID, Time))
		   ])
	     ]).

:- record
	  review(name:atom,
		 openid:atom,
		 time:number,
		 rating:integer,
		 comment:atom).

sort_reviews(By, Reviews, Sorted) :-
	map_list_to_pairs(review_data(By), Reviews, Keyed),
	keysort(Keyed, KeySorted),
	pairs_values(KeySorted, Sorted0),
	reverse(Sorted0, Sorted).

%%	show_review(+Pack, +OpenID)// is det.
%
%	Show an individual review about Pack

show_review(Pack, OpenID) -->
	{ review(Pack, OpenID, _Time, Rating, Comment),
	  http_link_to_id(pack_review, [p(Pack)], Update)
	},
	html([ div(class(review),
		   [ b('Reviewer: '),    \show_reviewer(OpenID), ', ',
		     b('Your rating: '), \show_rating_value(Pack, Rating, []),
		     b('Overall rating: '), \show_rating(Pack),
		     div(class(comment), \show_comment(Comment)),
		     div(class(update),
			 [ a(href(Update), 'Update'), ' my review'
			 ])
		   ])
	     ]),
	html_receive(rating_scripts).


show_reviewer(OpenID) -->
	{ site_user_property(OpenID, name(Name)),
	  Name \== ''
	}, !,
	html(Name).
show_reviewer(_OpenID) -->
	html(i(anonymous)).

show_reviewer(OpenID, Time) -->
	{ format_time(atom(Date), '%A %d %B %Y, ', Time)
	},
	html(Date),
	show_reviewer(OpenID).



show_rating(Pack) -->
	{ pack_rating_votes(Pack, Rating, Votes),
	  pack_comment_count(Pack, Count)
	},
	show_pack_rating(Pack, Rating, Votes, Count, []).

%%	show_pack_rating(+Pack)// is det.
%
%	Show overall rating. If there is no rating, offer to create one.

show_pack_rating(Pack) -->
	{ pack_rating_votes(Pack, Rating, Votes) },
	(   { Votes =:= 0 }
	->  { http_link_to_id(pack_review, [p(Pack)], HREF) },
	    html(span(class(not_rated),
		      [ 'Not rated.  ', a(href(HREF), 'Create'),
			' the first rating!'
		      ]))
	;   { pack_comment_count(Pack, Count) },
	    show_pack_rating(Pack, Rating, Votes, Count, [])
	).


%%	pack_rating_votes(+Pack, -Rating, -Votes) is det.
%
%	Rating is the current rating for Pack, based on Votes.

pack_rating_votes(Pack, Rating, Votes) :-
	aggregate_all(count-sum(R), pack_rating(Pack, R), Votes-Sum),
	Votes > 0, !,
	Rating is Sum/Votes.
pack_rating_votes(_Pack, 0, 0).

pack_rating(Pack, Rating) :-
	review(Pack, _, _, Rating, _),
	Rating > 0.

%%	pack_comment_count(Pack, Count)
%
%	True when Count is the number of comments for Pack.

pack_comment_count(Pack, Count) :-
	aggregate_all(count,
		      ( review(Pack, _, _, _, Comment),
			Comment \== ''
		      ),
		      Count).


show_rating_value(Pack, Value, Options) -->
	rate([ rate_max(5),
	       data_id(Pack),
	       type(small),
	       disabled(true),
	       class(rated),
	       post(rating_scripts),
	       data_average(Value)
	     | Options
	     ]).

%%	show_pack_rating(+Pack, +Rating, +Votes, +CommentCount,
%%			 +Options)// is det.
%
%	Show rating for Pack.

show_pack_rating(Pack, Rating, 0, 0, Options) --> !,
	show_rating_value(Pack, Rating, Options).
show_pack_rating(Pack, Rating, Votes, Count, Options) -->
	html(span(class(rating),
		  [ \show_rating_value(Pack, Rating, Options),
		    span(class(votes), ' (~D/~D)'-[Votes, Count])
		  ])).

%%	show_comment(+Comment)// is det.
%
%	Display Comment.  Comment is an atom holding Wiki text.

show_comment('') --> !,
	html(i('No comment')).
show_comment(Text) -->
	{ atom_codes(Text, Codes),
	  wiki_file_codes_to_dom(Codes, /, DOM0),
	  clean_dom(DOM0, DOM)
	},
	html(DOM).

clean_dom([p(X)], X).
