# Cache - Server side cache
# TODO: make Cache a direct domain for some introspection

package require Debug
Debug define cache 10	;# debug cache access decisions

package require Http
package require Direct
package provide Cache 2.0

set API(Server/Cache) {
    {
	Cache provides a reverse cache for any content generated by the server.  It is transparent, in that it obeys all relevant HTTP caching and freshness directives and also obeys the Wub-specific -dynamic directive.

	Cache is invoked prior to dispatch by [Httpd] in order to satisfy requests from cached content, and after Domain processing to cache any suitable responses.

	Cached content may be explicitly invalidated by URL, and old content will be superceded by newly generated content.

	== Note ==
	Cache ignores requests by the client to re-generate content, reasoning that it serves the server, not the client, and the server is better placed to know what needs caching.

	== ToDo ==
	Caching is really wrecked by spiders and bots ... their access patterns exhibit no locality of reference, expanding the working set beyond the useful confines of a cache.  Some way of detecting them needs to be worked out, so content produced for them doesn't fill the cache.
    }
}

oo::class create ::CacheClass {

    # has this cache content been modified since the time given?
    method filemodified? {req cached} {
	if {![dict exists $req if-modified-since] || ![dict exists $cached -file]} {
	    return 0	;# not interested in modifications or not a file at all
	}
	set since [Http DateInSeconds [dict get $req if-modified-since]]
	set mtime [file mtime [dict get $cached -file]]
	Debug.cache {filemodified? $since $mtime ergo: [expr {$since ne $mtime}]}
	return [expr {$since > $mtime}]
    }

    method counter {cached field} {
	variable cache
	dict incr cache([dict get $cached -key]) $field
    }

    # is this cache content fresh?
    method unmodified? {req cached} {
	# perform cache freshness check
	if {![dict exists $req if-modified-since]} {
	    Debug.cache {unmodified? 0 - no if-modified-since}
	    return 0
	}

	if {[Http any-match $req [dict get $cached etag]]} {
	    # this is looking for a completely different entity
	    # we haven't got that entity, so there's no way they can match
	    return 0
	}

	# cache check freshness against request's modification time
	set since [Http DateInSeconds [dict get $req if-modified-since]]
	set result [expr {$since >= [dict get $cached -modified]}]
	Debug.cache {unmodified? $since >= [dict get $cached -modified] -> $result}
	if {$result} {
	    my counter $cached -ifmod
	}
	return $result
    }

    # does this key exist in cache?
    method exists? {key} {
	if {$key eq ""} {return 0}	;# special case - no key

	variable keys
	set key [string trim $key \"]	;# remove ridiculous quotes
	Debug.cache {exists: $key - [info exists keys($key)]}
	return [info exists keys($key)]
    }

    # invalidate a cache entry.
    # 0: no such key
    # 1: key removed
    # 2: entry and key removed
    # -1: key removed, entry not removed
    method invalidate {key} {
	set key [string trim $key \"]	;# remove ridiculous quotes
	if {$key eq ""} {return 0}	;# special case - no key

	Debug.cache {invalidate: $key}
	variable keys
	variable cache
	if {[my exists? $key]} {
	    Debug.cache {invalidating $key} 4
	    set ckey $keys($key)	;# get cache key
	    set result 1	;# indicate key removed
	    if {[info exists cache($ckey)]} {
		set result -1
		dict incr cache($ckey) -refcount -1
		if {[dict get $cache($ckey) -refcount] <= 0} {
		    unset cache($ckey)	;# remove entry
		    set result 2
		}
	    }
	    unset keys($key)	;# remove key
	    Debug.cache {invalidated '$key'.}
	    return $result
	} else {
	    Debug.cache {invalidate - no such element '$key'.}
	    return 0
	}
    }

    # delete a key's content from the cache
    method delete {key} {
	Debug.cache {delete $key} 4
	if {[my exists? $key]} {
	    variable keys
	    set key [string trim $key \"]	;# remove ridiculous quotes
	    set ckey $keys($key) ;# key under which the cached value is stored
	    variable cache
	    if {[info exists cache($ckey)]} {
		Debug.cache {found cache: etag:'[dict get? $cache($ckey) etag]' url:'[dict get? $cache($ckey) -uri]'}
		set cached $cache($ckey)
		my invalidate [dict get? $cached etag]
		my invalidate [dict get? $cached -uri]
	    }
	    my invalidate $key	;# remove offered key
	}
    }

    # clear the whole cache
    method clear {} {
	variable keys
	foreach key [array get keys http:*] {
	    my delete $key
	}
    }

    # fetch - try to find an entry matching req
    method fetch {req} {
	Debug.cache {fetch: ([dumpMsg $req])}

	variable keys
	variable cache

	set uri [Url uri $req]
	dict set req -uri $uri	;# regenerate the url, just in case

	set et [string trim [dict get? $req etag] \"]
	if {$et ne "" && [my exists? $et]} {
	    # key by request's etag
	    set key $keys($et)
	    set found $et
	    set by "etag '$et'"
	} elseif {[my exists? $uri]} {
	    # key by request's URL
	    set key $keys($uri)
	    set found $uri
	    set by "uri '$uri'"
	} else {
	    error "Cache Fetching '$et'/'$uri', no match."
	}

	# maintain some stats for cache management
	variable hits; incr hits	;# count cache hit
	if {![info exists cache($key)]} {
	    my invalidate $found	;# remove offending key
	    error "Cache $key by $by does not exist."
	}

	set cached $cache($key)
	if {[dict exists $cached -file]} {
	    # the cached is a -file type, and the underlying file is newer
	    # so we invalidate the cached form
	    set when  [dict get $cached -modified]
	    set mtime [file mtime [dict get $cached -file]]
	    if {$when ne $mtime} {
		if {[my exists? [dict get? $cached etag]]} {
		    my invalidate [dict get $cached etag]
		}
		if {[my exists? [dict get $cached -uri]]} {
		    my invalidate [dict get $cached -uri]
		}
		return {}	;# cache was invalid
	    }
	} else {
	    # we have no way to know whether non-file contents changed
	}

	# return our cached content
	return $cached
    }

    # staleness of content
    method staleness {n} {
	variable cache;
	variable weight_age; variable weight_hits

	set c $cache($n);
	set hits [expr {[dict get $c -hits] + [dict get $c -unmod]}]
	set age [expr {[dict get $c -when] - [clock seconds]}]
	set weight [expr {($hits * $weight_hits) + ($age * $weight_age)}]
	return $weight
    }

    # stale_sort - return objects in staleness order
    # staleness is a measure of #hits and age of entry
    method stale_sort {a b} {
	variable cache;
	variable weight_age; variable weight_hits

	set weight_a [my staleness $a]
	set weight_b [my staleness $b]

	return [expr {int(100 * ($weight_b - $weight_a))}]
    }

    # etag - generate an etag for content
    method etag {req} {
	# use MD5 of content for etag
	if {[catch {
	    if {[dict exists $req -file]} {
		set result "WUB[Http md5file [dict get $req -file]]"
	    } else {
		set result "WUB[::md5::md5 -hex [dict get $req -content]]"
	    }
	} e eo]} {
	    Debug.error {etag: $e ($eo)}
	    variable uniq
	    set result "wub[incr uniq]"
	}
	return $result
    }

    # put - insert request into cache
    method put {req} {
	Debug.cache {put: ([dumpMsg $req])}
	
	set uri [Url uri $req]	;# clean up URL just in case
	dict set req -uri $uri

	# we only cache 200s
	if {[dict get $req -code] != 200} {
	    Debug.cache {code is [dict get $req -code] ... not caching $uri}
	    return $req
	}

	# allow application to avoid caching by setting -dynamic
	if {[dict exists $req -dynamic]
	    && [dict get $req -dynamic]
	} {
	    Debug.cache {content is -dynamic ... not caching $uri}
	    return $req
	}

	# whatever the eventual cache status, must remove old matches
	my invalidate [dict get $req -uri]		;# invalidate by -uri
	my invalidate [dict get? $req -etag]	;# invalidate by request etag
	my invalidate [dict get? $req etag]	;# invalidate by response etag

	# if there's no content, we can't cache
	if {![dict exists $req -content] && ![dict exists $req -file]} {
	    Debug.cache {no content provided ... not caching $uri}
	    return $req
	}

	# determine content size
	if {[dict exists $req -content]} {
	    set len [string length [dict get $req -content]]
	} elseif {[dict exists $req -file]} {
	    set len [file size [dict get $req -file]]
	}

	variable maxsize
	if {$maxsize > 0 && $maxsize < $len} {
	    # we can't store enormous entities in the cache
	    Debug.cache {content size $len >= $maxsize too big ... not caching $uri}
	    return $req
	}

	if {$len == 0} {
	    # we don't cache empty stuff
	    return $req
	}

	# we don't cache custom mime-typed content
	set ctype [dict get $req content-type]
	if {[string match x-*/* $ctype]} {
	    Debug.cache {content type $ctype ... not caching $uri}
	    return $req
	}

	Debug.cache {definitely caching $uri}

	if {[dict exists $req etag]} {
	    # let the domains generate their own etags
	    # hope they're consistent and unique ...
	    set etag [string trim [dict get $req etag] \"]
	    dict set req etag \"$etag\"	;# store with ridiculous quotes
	} else {
	    # generate etag from MD5 of content
	    set etag [my etag $req]
	    dict set req etag \"$etag\"	;# store with ridiculous quotes
	}

	# subset the cacheable request with just those fields needed
	set cached [dict in $req {-content -file -gzip
		-code -uri -charset -chconverted
		-modified -expiry -etag
		content-language content-location content-md5 content-type
		expires last-modified cache-control
	}]
	set cached [dict merge $cached [dict in $req $::Http::rs_headers]]

	# add new fields for server cache control
	dict set cached -refcount 2
	dict set cached -when [clock seconds]
	dict set cached -key $etag	;# remember the actual etag
	dict set cached -hits 0
	dict set cached -unmod 0
	dict set cached -ifmod 0
	if {![dict exists $cached -modified]} {
	    dict set cached -modified [clock seconds]
	}

	Debug.cache {cache entry: [Httpd dump $cached]} 4

	variable cache; variable high; variable low
	# ensure cache size is bounded
	set cachesize [array size cache]
	if {$cachesize > $high} {
	    set ordered [lsort -command [list [self] stale_sort] [array names cache]]
	    while {$cachesize > $low} {
		# pick a cache entry to remove by weight
		set c [lindex $ordered 0]
		set ordered [lrange $ordered 1 end]

		# remove the selected entry
		catch { # invalidate by -uri
		    my invalidate [dict get $cache($c) -uri]
		}
		catch { # invalidate by etag
		    my invalidate [dict get? $cache($c) etag]
		}

		incr cachesize -1
	    }
	}

	# insert cacheable request into cache under modified etag
	set cache($etag) $cached

	# insert keys into key array - match by -uri or etag
	variable keys
	set keys($etag) $etag
	set keys([dict get $req -uri]) $etag

	Debug.cache {new: $etag == [dict get $req -uri]}

	return $req	;# return, with etag and other fields
    }

    # keys - return keys matching filter (default all)
    method keys {{filter {}}} {
	variable keys
	return [array names keys {*}$filter]
    }

    # consistency - check or ensure cache consistency
    method consistency {{fix 1}} {
	variable keys
	variable cache
	set check 1
	while {$check} {
	    set check 0
	    foreach {name val} [array get keys] {
		if {$name eq $val} {
		    # etag key
		    if {![info exists cache($name)]} {
			Debug.error {etag key no matching cache $name}
			if {$fix} {
			    unset keys($name)
			    incr check
			}
		    }
		} else {
		    # url key
		    if {![info exists cache($val)]} {
			Debug.error {url key $name no matching cache $val}
			if {$fix} {
			    catch {unset keys($val)}
			    incr check
			}
		    }
		}
	    }

	    foreach {name val} [array get cache] {
		if {[catch {
		    if {![my exists? keys($name)]} {
			# no etag key for cache
			error {orphan cache by name '$name' / $cache($name)}
		    }
		    if {![my exists? [dict get $val -uri]]} {
			error {orphan cache by url '[dict get? $val -uri]' / $name - '$cache($name)'}
		    }
		    if {![my exists? [dict get $val etag]]} {
			error {orphan cache by etag '[dict get? $val etag]' / $name - '$cache($name)'}
		    }
		    if {[string trim [dict get $val etag] \"] ne $name} {
			error {etag and cache name mismatch}
		    }
		} r eo]} {
		    Debug.error {cache consistency: $eo}
		    if {$fix} {
			unset cache($name)
			incr check
		    }
		}
	    }
	}
    }

    # 2dict - convert cache to dict
    method 2dict {} {
	variable cache
	set result {}
	foreach {n v} [array get cache] {
	    if {[dict exists $v -content]} {
		dict set v -size [string length [dict get $v -content]]
	    } elseif {[dict exists $v -file]} {
		dict set v -size [file length [dict get $v -file]]
	    } else {
		dict set v -size 0
	    }
	    catch {dict unset v -content}
	    catch {dict unset v -gzip}
	    dict set v -stale [staleness $n]
	    dict set result $n $v
	}
	return $result
    }

    # check - can request be satisfied from cache?
    # if so, return it.
    method check {req} {
	Debug.cache {check [dict get $req -uri]: ([dumpMsg $req])}
	variable attempts; incr attempts	;# count cache attempts

	# first query cache to see if there's even a matching entry
	set etag [dict get? $req etag]
	if {$etag ne "" && ![my exists? $etag]} {
	    # client provided an etag
	    Debug.cache {etag '$etag' given, but not in cache}
	    return {}	;# we don't have a copy matching etag
	}

	set uri [Url uri $req]; #dict get? $req -uri
	if {$uri ne "" && ![my exists? $uri]} {
	    Debug.cache {url '$uri' not in cache}
	    return {}	;# we don't have a copy matching -uri either
	}

	# we have an etag or a uri which exists in Cache

	# old style no-cache request
	variable obey_CC
	variable CC
	if {$CC && "no-cache" in [split [dict get? $req pragma] ,]} {
	    # ignore no-cache, because we're the server, and in the best
	    # position to judge the freshness of our content.
	    Debug.cache {no-cache requested - we're ignoring those!}
	    if {$obey_CC} {return {}}
	}

	# split any cache control into an array
	if {$CC && [dict exists $req -cache-control]} {
	    foreach directive [split [dict get $req -cache-control] ,] {
		set body [string trim [join [lassign [split $directive =] d] =]]
		set d [string trim $d]
		set cc($d) $body
	    }
	    Debug.cache {no-cache requested [array get cc]}

	    if {[info exists cc(no-cache)]
		|| ([info exists cc(max-age)] && ($cc(max-age)==0))} {
		if {$obey_CC} {return {}}	;# no cache.
	    }

	    if {$obey_CC && [info exists cc(max-age)]} {
		# we ignore max_age
		set max_age [Http DateInSeconds $cc(max-age)]
	    }
	}

	# we may respond from cache, we *do* have a cached copy
	if {[catch {
	    my fetch $req
	} cached eo]} {
	    # it's gotta be there!
	    Debug.error {cache inconsistency '$cached' ($eo) - can't fetch existing entry for url:'$uri'/[exists? $uri] etag:'$etag'/[exists? $etag]}
	    return {}
	}
	if {$cached eq {}} {
	    return {}
	}

	if {[info exists max_age]
	    && ([dict get $cached -when] - [clock seconds]) > $max_age
	} {
	    # ignore the cache - this client wants newness
	    Debug.cache {older than max-age $max_age}
	    return {}
	}

	# re-state some fields of cache entry for possible NotModified
	foreach f {cache-control expires vary content-location} {
	    if {[dict exists $cached $f]} {
		dict set req $f [dict get $cached $f]
	    }
	}

	if {[my unmodified? $req $cached]} {
	    Debug.cache {unmodified $uri}
	    my counter $cached -unmod	;# count unmod hits
	    return [Http NotModified $req]
	    # NB: the expires field is set in $req
	} elseif {[my filemodified? $req $cached]} {
	    # the cached is a -file type, and the underlying file is newer
	    # so we invalidate the cached form
	    if {[my exists? [dict get? $req etag]]} {
		my invalidate [string trim [dict get $req etag] \"]
	    }
	    if {[my exists? [dict get $req -uri]]} {
		my invalidate [dict get $req -uri]
	    }
	    return {}
	} else {
	    # deliver cached content in lieue of processing
	    my counter $cached -hits	;# count individual entry hits
	    set req [dict merge $req $cached]
	    set req [Http CacheableContent $req [dict get $cached -modified]]
	    Debug.cache {cached content for $uri ([Httpd dump $req])}
	    return $req
	}

	Debug.cache {no cached version}
	return {}	;# no cache available
    }

    superclass Direct

    method /dump {r} {
	variable keys
	variable cache
	set etable [list [<tr> "[<th> key] [<th> url] [<th> age(s)] [<th> staleness]"]]
	set utable $etable
	set now [clock seconds]
	foreach {name val} [array get keys] {
	    if {$name eq $val} {
		# etag key
		set table etable
	    } else {
		# url key
		set table utable
	    }

	    if {![info exists cache($val)]} {
		set el [<tr> [<td> $name][<td> "no matching cache $val"]]
	    } else {
		set el [<tr> [<td> $name][<td> [dict get $cache($val) -uri]][<td> [expr {$now - [dict get $cache($val) -when]}]][<td> [my staleness $val]]]
	    }
	    lappend $table $el
	}
	set content [<h2> "Cache State"]
	append content [<table> [join $etable \n]]
	append content [<table> [join $utable \n]]
	return [Http Ok $r $content]
    }

    method / {r} {
	return [my /dump $r]
    }

    method new {args} {
	return [self]
    }

    # initialise the state of Cache
    constructor {args} {
	# high and low water mark for cache occupancy
	variable high 100
	variable low 90
	variable weight_age 0.02
	variable weight_hits -2.0

	# cache effectiveness stats
	variable hits 0
	variable attempts 0
	variable CC 0	;# do we bother to parse cache-control?
	variable obey_CC 0	;# do we act on cache-control? (Not Implemented)

	variable maxsize [expr {2 * 1024 * 1024}]	;# maximum size of object to cache
	variable mount ""
	variable {*}$args
	if {$mount ne ""} {
	    next mount $mount
	    ::Nub domain $mount Cache
	}

	variable keys	;# keys into cache
	array set keys {}
	variable cache	;# array of refcounted dicts
	array set cache {}
    }
}

