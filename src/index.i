<?xml version='1.0'?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>

  <head>

    <title>Prime Mover</title>

  </head>

  <body>

    <h1>Introduction</h1>

    <p>Prime Mover is a build tool, not unlike <tt>make</tt>. It is 
    designed to be small, portable, flexible, powerful, and is very 
    easy to deploy. It can be distributed along with your application 
    source code and does not require your end user to have anything 
    other than a basic C compiler in order to use it.</p>

    <p>For more information, see the <a href="about.html">About Prime 
    Mover</a> page.</p>

    <h1>Getting it</h1>

    <p>You can download any release of Prime Mover from the 
    <a href="http://sourceforge.net/project/showfiles.php?group_id=157791"
    >Sourceforge download site</a>.</p>

    <h1>Documentation</h1>

    <p>Read <a href="manual/index.html">the friendly manual</a>. You 
    may also 
    <a href="http://sourceforge.net/mailarchive/forum.php?forum_id=49184">
    join the happy mailing list</a>.</p>

    <h1>News</h1>

	<h2>2008-01-13</h2>
	
	<p>Release version 0.1.3. This is a bugfix release; %in% and %out% were
	previously only being honoured in simple{} nodes. They are now honoured
	in all nodes, which means they can be used from pm.install() calls.</p>
	
	<h2>2007-09-05</h2>
	
	<p>Release version 0.1.2.1. This is a bugfix release; occasionally deep in a
	hierarchy, things weren't being rebuilt when they should be (a combination of
	cfile { dynamicheaders } not rebuilding the dynamicheaders, and file {} not
	expanding its filename).</p>
	
	<p>(0.1.2 was a SVN tagging mistake and does not exist.)</p>
	
	<h2>2007-02-24</h2>
	
	<p>Released version 0.1.1. This is a bugfix release; <tt>{REDIRECT, ...}</tt> and
	<tt>{PARENT, ...}</tt> weren't working under some circumstances.</p>
	
    <h2>2006-10-12</h2>

    <p>First version released to the public!</p>

  </body>

</html>
