# WubTk.tcl - a domain built around coroutines from tcl8.6

package require Debug
Debug define wubtk 10
package require Http
package require md5

package require WubWidgets

package provide WubTk 1.0

set ::API(Domains/WubTk) {
    {WubTk - a Web emulation of Tk}
}

class create ::WubTk {
    # process request helper
    method do {r} {
	variable mount
	# calculate the suffix of the URL relative to $mount
	lassign [Url urlsuffix $r $mount] result r suffix path
	if {!$result} {
	    return [Httpd NotFound $r]	;# the URL isn't in our domain
	}

	set extra [lassign [split $suffix /] cmd]
	dict set r -extra [join $extra /]

	Debug.wubtk {process '$suffix' over '$mount' extra: '$extra'}
	
	if {$suffix eq "/" || $suffix eq ""} {
	    # this is a new call - create the coroutine
	    variable uniq; incr uniq
	    set cmd [::md5::md5 -hex $uniq[clock microseconds]]
	    dict set r -cmd $cmd

	    # construct a namespace for this command
	    namespace eval [namespace current]::Coros::$cmd [list namespace path [list ::WubWidgets [info object namespace [self]]]]	;# get WubWidgets and WubTk on the command path
	    namespace eval [namespace current]::Coros::$cmd {
		gridC create grid	;# make per-coro single instance of grid
		wmC create wm		;# make per-coro single instance of wm
	    }

	    # install the user code in the coro's namespace
	    variable lambda
	    namespace eval [namespace current]::Coros::$cmd $lambda	;# install the user code

	    Debug.wubtk {coroutine initialising - ($r) reply}
	    
	    set result [coroutine [namespace current]::Coros::${cmd}::_do ::apply [list {r} {
		set r [::yield]	;# we let the initial pass go

		# initial client direct request
		Debug.wubtk {processing [info coroutine]}
		set r [jQ jquery $r]
		set js {
		    $(".button").click(function () { 
			$.ajax({
			    context: this,
			    type: "GET",
			    url: "button",
			    data: {id: $(this).attr("name")},
			    dataType: "script",
			    success: function (data, textStatus, XMLHttpRequest) {
				//alert("button: "+data);
			    }
			});
		    });

		    $(".variable").click(function () { 
			$.ajax({
			    context: this,
			    type: "GET",
			    url: "variable",
			    data: {id: $(this).attr("name")},
			    dataType: "script",
			    success: function (data, textStatus, XMLHttpRequest) {
				//alert("button: "+data);
			    }
			});
		    });

		    $(".command").change(function callback(eventObject) {
			$.ajax({
			    context: this,
			    type: "GET",
			    url: "command",
			    data: {id: $(this).attr("name")},
			    dataType: "script",
			    success: function (data, textStatus, XMLHttpRequest) {
				//alert("command: "+data);
			    }
			});
		    });
		}
		set r [jQ ready $r $js]
		set content [grid render [namespace tail [info coroutine]]]
		Debug.wubtk {render: $content}
		dict set r -title [wm title]
		set r [Http Ok $r $content x-text/html-fragment]

		while {1} {
		    set r [::yield $r]	;# generate page or changes
		    # unpack query response
		    set Q [Query parse $r]; dict set r -Query $Q; set Q [Query flatten $Q]
		    Debug.wubtk {[info coroutine] Event: [dict get? $r -extra] ($Q)}
		    switch -- [dict get? $r -extra] {
			button {
			    set cmd .[dict Q.id]
			    if {[llength [info commands [namespace current]::$cmd]]} {
				Debug.wubtk {button $cmd}
				$cmd command
			    } else {
				Debug.wubtk {not found button [namespace current]::$cmd}
			    }
			}
			var {
			}
			command {
			}
		    }
		    set result ""
		    dict for {id html} [grid changes] {
			append result [string map [list %ID% $id %H% $html] {
			    $('#%ID%').replaceWith("%H%");
			}]
		    }
		    if {$result ne ""} {
			append result $js
		    }
		    set r [Http Ok $r $result text/javascript]
		}
	    } [namespace current]::Coros::$cmd] $r]

	    if {$result ne ""} {
		Debug.wubtk {coroutine initialised - ($r) reply}
		return $result	;# allow coroutine lambda to reply
	    } else {
		# otherwise simply redirect to coroutine lambda
		Debug.wubtk {coroutine initialised - redirect to ${mount}$cmd}
		return [Http Redirect $r [string trimright $mount /]/$cmd/]
	    }
	}

	if {[namespace which -command [namespace current]::Coros::${cmd}::_do] ne ""} {
	    # this is an existing coroutine - call it and return result
	    Debug.wubtk {calling coroutine '$cmd' with extra '$extra'}
	    if {[catch {
		[namespace current]::Coros::${cmd}::_do $r
	    } result eo]} {
		Debug.error {'$cmd' error: $result ($eo)}
		return [Http ServerError $r $result $eo]
	    }
	    Debug.wubtk {'$cmd' yielded: ($result)}
	    return $result
	} else {
	    Debug.wubtk {coroutine gone: $cmd}
	    return [Http Redirect $r [string trimright $mount /]/]
	    return [Http NotFound $r [<p> "WubTk '$cmd' has terminated."]]
	}
    }

    destructor {
	namespace delete Coros
    }

    superclass FormClass	;# allow Form to work nicely
    constructor {args} {
	variable hint 1
	variable {*}[Site var? WubTk]	;# allow .ini file to modify defaults
	variable {*}$args
	namespace eval [info object namespace [self]]::Coros {}
	next {*}$args
    }
}