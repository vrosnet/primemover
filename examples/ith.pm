-- $Id$
-- $HeadURL$
-- $LastChangedDate$

include "lib/c.pm"

DIR = "examples/source"

dynamic_outputs = simple {
	outputs = {"%U%/first.c", "%U%/second.c", "%U%/third.c"},
	command = {
		"echo 'int foo() { return 1; }' > %out[1]%",
		"echo 'int foo() { return 2; }' > %out[2]%",
		"echo 'int foo() { return 3; }' > %out[3]%"
	},
	file "%DIR%/test.c"
}

default = cprogram {
	cfile "%DIR%/test.c",
	
	-- ith selects one input and discards the others. Because dynamic_outputs
	-- must generate three output files --- because of the way it works ---
	-- and we only want to build one, we use ith to select the second of its
	-- outputs while ignoring the others.
	
	cfile {
		ith { dynamic_outputs, i = 2 }
	},
	
	install = pm.install("%DIR%/ith")
}
