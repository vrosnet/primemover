#!/usr/bin/lua
-- Prime Mover
--
-- © 2006-2007 David Given.
-- Prime Mover is licensed under the MIT open source license. Search
-- for 'MIT' in this file to find the full license text.
--
-- $Id$

-- ======================================================================= --
--                                GLOBALS                                  --
-- ======================================================================= --

local VERSION = "0.1.5"

-- Fast versions of useful system variables.

local stdin = io.stdin
local stdout = io.stdout
local stderr = io.stderr

local string_find = string.find
local string_gsub = string.gsub
local string_sub = string.sub
local string_byte = string.byte

local table_insert = table.insert
local table_getn = table.getn
local table_concat = table.concat

local posix_stat = posix.stat
local posix_readlink = posix.readlink
local posix_unlink = posix.unlink
local posix_rmdir = posix.rmdir

local os_time = os.time

local _G = _G
local _

-- Option settings.

local delete_output_files_on_error = true
local purge_intermediate_cache = false
local no_execute = false
local input_files = {}
local targets = {}
intermediate_cache_dir = ".pm-cache/"
verbose = false
quiet = false

-- Application globals.

local sandbox = {}
local scope = {object=sandbox, next=nil}
local intermediate_cache = {}
local intermediate_cache_count = 0
local buildstages = 0

-- Atoms.

local PARENT = {}
local EMPTY = {}
local REDIRECT = {}

-- Exported symbols (set to dummy values).

message = 0
filetime = 0
filetouch = 0
install = 0
rendertable = 0
stringmodifier = {}

setmetatable(_G, {__newindex = function(t, key, value)
	error("Attempt to write to new global "..key)
end})

-- ======================================================================= --
--                               UTILITIES                                 --
-- ======================================================================= --

local function message(...)
	stderr:write("pm: ")
	stderr:write(unpack(arg))
	stderr:write("\n")
end
_G.message = message

local function usererror(...)
	stderr:write("pm: ")
	stderr:write(unpack(arg))
	stderr:write("\n")
	os.exit(1)
end

local function traceoutput(...)
	stdout:write(unpack(arg))
	stdout:write("\n")
end

local function assert(message, result, e)
	if result then
		return result
	end
	
	if (type(message) == "string") then
		message = {message}
	end
	
	table.insert(message, ": ")
	table.insert(message, e)
	usererror(unpack(message))
end

-- Concatenates the contents of its arguments to the specified table.
-- (Numeric indices only.)

local function table_append(t, ...)
	for _, i in ipairs(arg) do
		if (type(i) == "table") then
			for _, j in ipairs(i) do
				table_insert(t, j)
			end
		else
			table_insert(t, i)
		end
	end
end

-- Merge the contents of its arguments to the specified table.
-- (Name indices. Will break on numeric indices.)

local function table_merge(t, ...)
	for _, i in ipairs(arg) do
		for j, k in pairs(i) do
			t[j] = k
		end
	end
end

-- Turn a list of strings into a single quoted string.

function rendertable(i, tolerant)
	if (type(i) == "string") or (type(i) == "number") then
		return i
	end
	
	if (i == nil) or (i == EMPTY) then
		return ""
	end
	
	local t = {}
	for _, j in ipairs(i) do
		if (type(j) ~= "string") and (type(j) ~= "number") then
			if tolerant then
				j = "[object]"
			else
				error("attempt to expand a list containing an object")
			end
		end
		
		local r = string_gsub(j, "\\", "\\\\")
		r = string_gsub(r, '"', '\\"')
		table_insert(t, r)
	end
	return '"'..table_concat(t, '" "')..'"'
end
local rendertable = rendertable

-- Returns just the directory part of a path.

local function dirname(f)
	local f, n = string_gsub(f, "/[^/]*$", "")
	if (n == 0) then
		return "."
	end
	return f
end
posix.dirname = dirname

-- Makes an absolute path.

local function absname(f)
	if string.find(f, "^/") then
		return f
	end
	
	return posix.getcwd().."/"..f
end
posix.absname = absname

-- Copies a file.

local function copy(src, dest)
	local s = string_gsub(src, "'", "'\"'\"'")
	local d = string_gsub(dest, "'", "'\"'\"'")
	local r = os.execute("cp '"..s.."' '"..d.."'")
	if (r ~= 0) then
		return nil, "unable to copy file"
	end
	return 0, nil
end
posix.copy = copy
	
-- Makes all directories that contain f

local function mkcontainerdir(f)
	f = dirname(f)
	if not posix_stat(f, "type") then
		mkcontainerdir(f)
		local r = posix.mkdir(f)
		if not r then
			usererror("unable to create directory '"..f.."'")
		end
	end
end

-- Install a file (suitable as a command list entry).

local function do_install(self, src, dest)
	src = absname(self:__expand(src))
	dest = absname(self:__expand(dest))
	if verbose then
		message("installing '", src, "' --> '", dest, "'")
	end
	
	mkcontainerdir(dest)
	local f, e = posix.symlink(src, dest)
	if f then
		return
	end

	if (e ~= nil) then
		f, e = posix.unlink(dest)
		if f then
			f, e = posix.symlink(src, dest)
			if f then
				return
			end
		end
	end
	
	self:__error("couldn't install '", src, "' to '", dest,
			"': ", e)
end

function install(src, dest)
	return function(self, inputs, outputs)
		local src = src
		local dest = dest
		
		if (dest == nil) then
			dest = src
			src = outputs[1]
		end
		if (type(src) ~= "string") then
			self:__error("pm.install needs a string or an object for an input")
		end
		if (type(dest) ~= "string") then
			self:__error("pm.install needs a string for a destination")
		end
		return do_install(self, src, dest)
	end
end

-- Perform an error traceback.

local function traceback(e)
	local i = 1
	while true do
		local t = debug.getinfo(i)
		if not t then
			break
		end
		if (t.short_src ~= "stdin") and (t.short_src ~= "[C]") then
			if (t.currentline == -1) then
				t.currentline = ""
			end
			message("  ", t.short_src, ":", t.currentline)
		end
		i = i + 1
	end
	
	e = string_gsub(e, "^stdin:[0-9]*: ", "")
	usererror("error: ", e)
end

-- ======================================================================= --
--                            CACHE MANAGEMENT                             --
-- ======================================================================= --

local statted_files = {}
local function clear_stat_cache()
	statted_files = {}
end

-- Returns the timestamp of a file, or 0 if it doesn't exist.

local statted_files = {}
local function filetime(f)
	local t = statted_files[f]
	if t then
		return t
	end
	
	-- Stupid BeOS doesn't dereference symlinks on stat().
	
	local realf = f
	while true do
		local newf, e = posix_readlink(realf)
		if e then
			break
		end
		realf = newf
	end
	
	t = posix_stat(realf, "mtime") or 0
	statted_files[f] = t
	return t
end
_G.filetime = filetime

-- Pretends to touch a file by manipulating the stat cache.

local function filetouch(f)
	if (type(f) == "string") then
		f = {f}
	end
	
	local t = os_time()
	for _, i in ipairs(f) do
		statted_files[i] = t
	end
end
_G.filetouch = filetouch

local function create_intermediate_cache()
	local d = dirname(intermediate_cache_dir)
	if not quiet then
		message("creating new intermediate file cache in '"..d.."'")
	end
	
	-- Attempt to wipe the old cache directory.
	
	local f = posix.files(d)
	if not f then
		-- The directory doesn't exist, so create it.
		
		mkcontainerdir(d)
		f = posix.mkdir(d)
		if not f then
			usererror("unable to create intermediate file cache directory")
		end
	else
		-- The directory exists. Delete all files in it recursively.
		
		local function rmdir(root)
			local f = posix.files(root)
			if not f then
				return
			end
			
			for i in f do
				if ((i ~= ".") and (i ~= "..")) then
					local fn = root.."/"..i
					local t = posix_stat(fn, "type")
					if (t == "regular") then
						if not posix_unlink(fn) then
							usererror("unable to purge intermediate file cache directory")
						end
					elseif (t == "directory") then
						rmdir(fn)
						posix_rmdir(fn)
					end
				end
			end
		end
		
		rmdir(d)
	end
end

local function save_intermediate_cache()
	local fn = intermediate_cache_dir.."index"
	local f = io.open(fn, "w")
	if not f then
		usererror("unable to save intermediate cache index file '", fn, "'")
	end
	
	f:write(intermediate_cache_count, "\n")
	for i, j in pairs(intermediate_cache) do
		f:write(i, "\n")
		f:write(j, "\n")
	end
	
	f:close()
end

local function load_intermediate_cache()
	local fn = intermediate_cache_dir.."index"
	local f = io.open(fn, "r")
	if not f then
		create_intermediate_cache()
		return
	end
	
	intermediate_cache_count = f:read("*l")
	while true do
		local l1 = f:read("*l")
		local l2 = f:read("*l")
		
		if (l1 == nil) or (l2 == nil) then
			break
		end
		
		intermediate_cache[l1] = l2
	end
	
	f:close()
end

local function create_intermediate_cache_key(key)
	local u = intermediate_cache[key]
	if not u then
		intermediate_cache_count = intermediate_cache_count + 1	
		u = intermediate_cache_count
		intermediate_cache[key] = u
		save_intermediate_cache()
	end
	
	return u
end

-- ======================================================================= --
--                            STRING MODIFIERS                             --
-- ======================================================================= --

function stringmodifier.dirname(self, s)
	if (type(s) == "table") then
		if (table_getn(s) == 1) then
			s = s[1]
		else
			self:__error("tried to use string modifier 'dirname' on a table with more than one entry")
		end
	end
	
	return dirname(s)
end

-- ======================================================================= --
--                              CLASS SYSTEM                               --
-- ======================================================================= --

--- Base class --------------------------------------------------------------

local metaclass = {
	class = "metaclass",
	
	-- Creates a new instance of a class by creating a new object and cloning
	-- all properties of the called class onto it.
	
	__call = function (self, ...)
		local o = {}
		for i, j in pairs(self) do
			o[i] = j
		end
		setmetatable(o, o)
		
		-- Determine where this object was defined.
		
		local i = 1
		while true do
			local s = debug.getinfo(i, "Sl")
			if s then
				if (string_byte(s.source) == 64) then
					o.definedat = string_sub(s.source, 2)..":"..s.currentline
				end
			else
				break
			end
			i = i + 1
		end

		-- Call the object's constructor and return it.
				
		o:__init(unpack(arg))
		return o
	end,
	
	-- Dummy constructor.
	
	__init = function (self, ...)
	end,
}
setmetatable(metaclass, metaclass)

--- Top-level build node ----------------------------------------------------

local node = metaclass()
node.class = "node"

-- When constructed, nodes initialise themselves from a supplied table of
-- properties. All node children take exactly one argument, allowing the
-- "constructor {properties}" construction pattern.

function node:__init(t)
	metaclass.__init(self)
	
	if (type(t) == "string") then
		t = {t}
	end
	if (type(t) ~= "table") then
		self:__error("can't be constructed with a ", type(t), "; try a table or a string")
	end
	
	-- Copy over non-numeric parameters.
	
	for i, j in pairs(t) do
		if (tonumber(i) == nil) then
			self[i] = j
		end
	end

	-- Copy any numeric parameters.
	
	for _, i in ipairs(t) do
		table_insert(self, i)
	end
	
	-- If we're a class, don't verify.
	
	if t.class then
		return
	end

	-- ensure_n_children
	-- When true, ensures that the node has exactly the number of children
	-- specified.
	
	if self.ensure_n_children then
		local n = self.ensure_n_children
		if (table.getn(self) ~= n) then
			local one
			if (n == 1) then
				one = "one child"
			else
				one = n.." children"
			end
			self:_error("must have exactly ", one)
		end
	end
	
	-- ensure_at_least_one_child
	-- When true, ensures the the node has at least one child.
		
	if self.ensure_at_least_one_child then	
		if (table_getn(self) < 1) then
			self:__error("must have at least one child")
		end
	end
			
	-- construct_string_children_with
	-- If set, any string children are automatically converted using the
	-- specified constructor.
	
	if self.construct_string_children_with then
		local constructor = self.construct_string_children_with
		for i, j in ipairs(self) do
			if (type(j) == "string") then
				self[i] = constructor {j}
			end
		end
	end
			
	-- all_children_are_objects
	-- When true, verifies that all children are objects and not something
	-- else (such as strings).

	if self.all_children_are_objects then			
		for i, j in ipairs(self) do
			if (type(j) ~= "table") then
				self:__error("doesn't know what to do with child ", i,
					", which is a ", type(j))
			end
		end
	end
	
	-- Ensure that self.install is valid.
	
	if self.install then
		local t = type(self.install)
		if (t == "string") or
		   (t == "function") then
			self.install = {self.install}
		end
		
		if (type(self.install) ~= "table") then
			self:__error("doesn't know what to do with its installation command, ",
				"which is a ", type(self.install), " but should be a table, function ",
				"or string")
		end
	end
end

-- If an attempt is made to access a variable on a node that doesn't exist,
-- and the variable starts with a capital letter, it's looked up in the
-- property scope.

function node:__index(key)
	local i = string_byte(key, 1)
	if (i >= 65) and (i <= 90) then
		-- Scan up the class hierarchy.
		
		local recurse
		recurse = function(s, key)
			if not s then
				return nil
			end
			local o = rawget(s.object, key)
			if o then
				if (type(o) == "table") then

					-- Handle lists of the form {PARENT, "foo", "bar"...}					
					if (o[1] == PARENT) then
						local parent = recurse(s.next, key)
						local newo = {}
						
						if parent then
							if (type(parent) ~= "table") then
								parent = {parent}
							end
							for _, j in ipairs(parent) do
								table_insert(newo, j)
							end
						end
						for _, j in ipairs(o) do
							if (j ~= PARENT) then
								table_insert(newo, j)
							end
						end
						return newo

					-- Handle lists of the form {REDIRECT, "newkey"}
					elseif (o[1] == REDIRECT) then
						return self:__index(o[2])
					end
				end
				return o
			end
			-- Tail recursion.
			return recurse(s.next, key)
		end
		
		-- We want this node looked at first, so fake up a scope entry for it.
		local fakescope = {
			next = scope,
			object = self
		}
		
		-- Tail recursion.
		return recurse(fakescope, key)
	end
	
	-- For local properties, just return what's here.
	return rawget(self, key)
end

-- Little utility that emits an error message.

function node:__error(...)
	usererror("object '", self.class, "', defined at ",
		self.definedat, ", ", unpack(arg))
end

-- Causes a node to return its outputs; that is, the files the node will
-- produce when built. The parameter contains a list of input filenames; the
-- outputs of the node's children.

function node:__outputs(inputs)
	self:__error("didn't implement __outputs when it should have")
end

-- Causes a node to return its dependencies; that is, a list of *filenames*
-- whose timestamps need to be considered when checking whether a node needs
-- to be rebuilt. This is usually, but not always, the same as the inputs.

function node:__dependencies(inputs, outputs)
	return inputs
end

-- Returns the node's timestamp. It will only get built if this is older than its
-- children's timestamps.

function node:__timestamp(inputs, outputs)
	local t = 0
	for _, i in ipairs(outputs) do
		local tt = filetime(i)
		if (tt > t) then
			t = tt
		end
	end
	return t
end

-- Unconditionally builds the nodes' children, collating their outputs. We
-- push a new scope while we do so, to make this object's definitions visible
-- to the children. (Almost never overridden. Only file() will want to do
-- this, most likely.)

function node:__buildchildren()
	local inputs = {}
	scope = {object=self, next=scope}
	
	for _, i in ipairs(self) do
		table_append(inputs, i:__build())
	end
	self:__buildadditionalchildren()
	scope = scope.next
	return inputs
end

-- Provides a hook for building any additional children that aren't actually
-- in the child list.

function node:__buildadditionalchildren()
end

-- Cause the node's children to be built, collating their outputs, and if
-- any output is newer than the node itself, causes the node to be built.

function node:__build()
	-- Build children and collate their outputs. These will become this node's
	-- inputs. 
	
	local inputs = self:__buildchildren()
 	self["in"] = inputs
	
	-- Determine the node's outputs. This will usually be automatically
	-- generated, in which case the name will depend on the overall environment ---
	-- including the inputs.
	
	local outputs = self:__outputs(inputs)
	self.out = outputs
	
	-- Get the current node's timestamp. If anything this node depends on is
	-- newer than that, the node needs rebuilding.
	
	local t = self:__timestamp(inputs, outputs)
	local depends = self:__dependencies(inputs, outputs)
	local rebuild = false

	if (t == 0) then
		rebuild = true
	end
		
	if (not rebuild and depends) then
		for _, i in ipairs(depends) do
			local tt = filetime(i)
--			message("comparing ", t, " with ", tt, " (", rendertable({i}), ")")
			if (tt > t) then
				if verbose then
					message("rebuilding ", self.class, " because ", i, " (", tt, ") newer than ",
						rendertable(outputs), " (", t, ")")
				end
				rebuild = true
				break
			end
		end
	end

	if rebuild then
		self:__dobuild(inputs, outputs)
		filetouch(outputs)
	end
	
	-- If an installation command was specified, execute it now.
	
	if self.install then
		self:__invoke(self.install, inputs, outputs)
	end
	
	-- And return this nodes' outputs.
	
	return outputs
end

-- Builds this node from the specified input files (the node's childrens'
-- outputs).

function node:__dobuild(inputs, outputs)
	self:__error("didn't implement __dobuild when it should have")
end

-- Recursively expands any variables in a string.

local PERCENT = "\aPERCENT\a"
function node:__expand(s)
	local searching = true
	while searching do
		searching = false
		
		-- Expand %{expressions}%
		
		s = string_gsub(s, "%%{(.-)}%%", function (expr)
			searching = true

			local f, e = loadstring(expr, "expression")
			if not f then
				self:__error("couldn't compile the expression '", expr, "': ", e)
			end
			
			local env = {self=self}
			setmetatable(env, {
				__index = function(_, key)
					return sandbox[key]
				end
			})
			setfenv(f, env)
			
			f, e = pcall(f, self)
			if not f then
				self:__error("couldn't evaluate the expression '", expr, "': ", e)
			end

			return rendertable(e)			
		end)

		-- Expand %varnames%
		
		s = string_gsub(s, "%%(.-)%%", function (varname)
			searching = true

			-- Empty sequences become the magic PERCENT sequence. These get
			-- processed into literal % symbols at the end. We don't do it
			-- here, because otherwise the string expansion code gets very
			-- confused because it sees unmatched % signs.
			
			if (varname == "") then
				return PERCENT
			end
			
			-- Parse the string reference.
			
			local _, _, leftcolon, rightcolon = string_find(varname, "([^:]*):?(.*)$")
			local _, _, varname, selectfrom, hyphen, selectto = string_find(leftcolon, "^([^[]*)%[?([^-%]]*)(%-?)([^%]]*)]?$")
			
			-- Get the basic value that the rest of the reference is going to
			-- depend on.
			
			local result = self:__index(varname)
			if not result then
				self:__error("doesn't understand variable '", varname, "'")
			end

			-- Process any selector, if specified.
			
			if (selectfrom ~= "") or (hyphen ~= "") or (selectto ~= "") then
				if (type(result) ~= "table") then
					self:__error("tried to use a [] selector on variable '", varname,
						"', which doesn't contain a table")
				end
				local n = table_getn(result)

				selectfrom = tonumber(selectfrom)
				selectto = tonumber(selectto)
								
				if (hyphen ~= "") then
					if not selectfrom then
						selectfrom = 1
					end
					if not selectto then
						selectto = n
					end
				else
					if not selectto then
						selectto = selectfrom
					end
					if not selectfrom then
						self:__error("tried to use an empty selector on variable '", varname, "'")
					end
				end
				
				if (selectfrom < 1) or (selectto < 1) or
				   (selectfrom > n) or (selectto > n) or
				   (selectto < selectfrom) then
					self:__error("tried to use an invalid selector [",
						selectfrom, "-", selectto, "] on variable '", varname,
						"'; only [1-", n, "] is valid")
				end
				
				local newresult = {}
				for i = selectfrom, selectto do
					table_insert(newresult, result[i])
				end
				result = newresult
			end
			
			-- Process any string modifier, if supplied.
			
			if (rightcolon ~= "") then
				local f = stringmodifier[rightcolon]
				if not f then
					self:__error("tried to use an unknown string modifier '",
						rightcolon, "' on variable '", varname, "'")
				end
				
				result = f(self, result)
			end
				
			return rendertable(result)
		end)
	end
	
	-- Convert our saved PERCENT sequences back into singleton percentage
	-- signs.
	
	s = string_gsub(s, PERCENT, "%%")
	return s
end

-- Expands any variables in a command table, and executes it.

function node:__invoke(command, inputs, outputs)
	if (type(command) ~= "table") then
		command = {command}
	end
	
	for _, s in ipairs(command) do
		if (type(s) == "string") then
			s = self:__expand(s)
			if not quiet then
				traceoutput(s)
			end
			if not no_execute then
				local r = os.execute(s)
				if (r ~= 0) then
					return r
				end
			end
		elseif (type(s) == "function") then
			local r = s(self, inputs, outputs)
			if r then
				return r
			end
		end
	end
	return false
end

-- ======================================================================= --
--                                PROLOGUE                                 --
-- ======================================================================= --

-- The prologue contains the standard library that all pmfiles can refer to.
-- For simplicity, it's implemented by code running inside the sandbox,
-- which means that it's basically identical to user code (and could, in
-- fact, be kept in a seperate file).

-- Here we set up the sandbox.

table_merge(sandbox, {
	VERSION = VERSION,
	
	assert = assert,
	collectgarbage = collectgarbage,
	dofile = dofile,
	error = error,
	getfenv = getfenv,
	getmetatable = getmetatable,
	gcinfo = gcinfo,
	ipairs = ipairs,
	loadfile = loadfile,
	loadlib = loadlib,
	loadstring = loadstring,
	next = next,
	pairs = pairs,
	pcall = pcall,
	print = print,
	rawequal = rawequal,
	rawget = rawget,
	rawset = rawset,
	require = require,
	setfenv = setfenv,
	setmetatable = setmetatable,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	unpack = unpack,
	_VERSION = _VERSION,
	xpcall = xpcall,
	
	table = table,
	io = io,
	os = os,
	posix = posix,
	string = string,
	debug = debug,
	loadlib = loadlib,
	
	pm = _G,
	node = node,
	
	PARENT = PARENT,
	EMPTY = EMPTY,
	REDIRECT = REDIRECT,
})

-- Cause any reads from undefined keys in the sandbox to fail with an error.
-- This helps debugging pmfiles somewhat.

setmetatable(sandbox, {
	__index = function(self, key)
		local value = rawget(self, key)
		if (value == nil) then
			error(key.." could not be found in any applicable scope")
		end
		return value
	end
})

-- Switch into sandbox mode.

setfenv(1, sandbox)

--- Assorted utilities ------------------------------------------------------

-- Includes a file.

function include(f, ...)
	local c, e = loadfile(f)
	if not c then
		usererror("script compilation error: ", e)
	end
	
	setfenv(c, sandbox)
	local arguments = arg
	xpcall(
		function()
			c(unpack(arguments))
		end,
		function(e)
			message("script execution error --- traceback follows:")
			traceback(e)
		end
	)
end

--- file --------------------------------------------------------------------

-- file() is pretty much the simplest clause. It takes a list of filenames,
-- and outputs them.
--
--  * Building does nothing.
--  * Its outputs are its inputs.
--
-- Note: this clause only takes *strings* as its children. If a reference is
-- made to a file that doesn't exist, an error occurs.

file = node {
	class = "file",
 	ensure_at_least_one_child = true,
  	
  __init = function(self, p)
 		node.__init(self, p)
  		
		-- If we're a class, don't verify.
		
		if ((type(p) == "table") and p.class) then
			return
		end
		
 		-- Ensure that the file's children are strings.
  		
		for i, j in ipairs(self) do
			if (type(j) ~= "string") then
				self:__error("doesn't know what to do with child ", i,
					", which is a ", type(j))
			end
		end
 	end,

	-- File's timestamp is special and will bail if it meets a nonexistant file.
	
	__timestamp = function(self, inputs, outputs) 	
		local t = 0
		for _, i in ipairs(outputs) do
			i = self:__expand(i)
			local tt = filetime(i)
			if (tt == 0) then
				self:__error("is referring to the file '", i, "' which does not exist")
			end
			if (tt > t) then
				t = tt
			end
		end
		return t
	end,

 	-- Outputs are inputs.
 	
 	__outputs = function(self, inputs)
		local o = {}
		local n
 		if self.only_n_children_are_outputs then
 			n = self.only_n_children_are_outputs
 		else
 			n = table_getn(inputs)
 		end
 		
 		for i = 1, n do
 			o[i] = self:__expand(inputs[i])
 		end
 		
 		return o
 	end,
 	
 	-- Building children does nothing; outputs are inputs.
 	
 	__buildchildren = function(self)
 		local outputs = {}
 		table_append(outputs, self)
 		return outputs
 	end,
 	
 	-- Building does nothing.
 	
 	__dobuild = function(self, inputs, outputs)
 	end,
}
 
--- group -------------------------------------------------------------------

-- group() is also the simplest clause. It does nothing, existing only to
-- group together its children.

group = node {
	class = "group",
  	
 	-- Outputs are inputs.
 	
 	__outputs = function(self, inputs)
 		return inputs
 	end,
 	
 	-- Building does nothing.
 	
 	__dobuild = function(self, inputs, outputs)
 	end,
}

--- deponly -----------------------------------------------------------------

-- deponly() is the one-and-a-halfth most simplest clause. It acts like
-- group {}, but returns no outputs. It's useful for ensuring that building
-- one node causes another node to be built without actually using the
-- second node's outputs.

deponly = node {
	class = "deponly",
 	ensure_at_least_one_child = true,
	
 	-- Emits no outputs
 	
 	__outputs = function(self, inputs)
		return {}
 	end,
 	
 	-- Building does nothing.
 	
 	__dobuild = function(self, inputs, outputs)
 	end,
}

--- ith ---------------------------------------------------------------------

-- ith() is the second simplest clause. It acts like group {}, but returns
-- only some of the specified output. It is suitable for extracting, say,
-- one output from a clause to pass to cfile {}.

ith = node {
	class = "ith",
 	ensure_at_least_one_child = true,
  	
	__init = function(self, p)
 		node.__init(self, p)
  		
		-- If we're a class, don't verify.
		
		if ((type(p) == "table") and p.class) then
			return
		end

		-- If we have an i property, ensure we don't have a from or
		-- to property.
		
		if self.i then
			if self.from or self.to then
				self:__error("can't have both an i property and a from or to property")
			end
			
			if (type(self.i) ~= "number") then
				self:__error("doesn't know what to do with its i property, ",
					"which is a ", type(self.i), " where a number was expected")
			end

			self.from = self.i
			self.to = self.i
		end
		
		-- Ensure the from and to properties are numbers, if they exist.
		
		if self.from then
			if (type(self.from) ~= "number") then
				self:__error("doesn't know what to do with its from property, ",
					"which is a ", type(self.from), " where a number was expected")
			end
		end
		
		if self.to then
			if (type(self.to) ~= "number") then
				self:__error("doesn't know what to do with its to property, ",
					"which is a ", type(self.to), " where a number was expected")
			end
		end
 	end,

 	-- Emits one output, which is one of the inputs.
 	
 	__outputs = function(self, inputs)
 		local n = table_getn(inputs)
 		local from = self.from or 1
 		local to = self.to or n
 		
 		if (from < 1) or (to > n) then
 			self:__error("tried to select range ", from, " to ", to,
 				" from only ", n, " inputs")
 		end
 		
 		local range = {}
 		for i = from, to do
 			table_append(range, inputs[i])
 		end
 		return range
 	end,
 	
 	-- Building does nothing.
 	
 	__dobuild = function(self, inputs, outputs)
 	end,
}


--- foreach -----------------------------------------------------------------

-- foreach {} is the counterpart to ith {}. It applies a particular rule to
-- all of its children.

foreach = node {
	class = "foreach",
  	
	__init = function(self, p)
 		node.__init(self, p)
  		
		-- If we're a class, don't verify.
		
		if ((type(p) == "table") and p.class) then
			return
		end

		-- Ensure we have a rule property which is a table.
		
		if not self.rule then
			self:__error("must have a rule property")
		end
		if (type(self.rule) ~= "table") then
			self:__error("doesn't know what to do with its rule property, ",
				"which is a ", type(self.rule), " where a table was expected")
		end
 	end,

	-- Build all our children via the rule.
	--
	-- This is pretty much a copy of node.__buildchildren().
	
	__buildchildren = function(self)
		scope = {object=self, next=scope}

		local intermediate = {}
		for _, i in ipairs(self) do
			table_append(intermediate, i:__build())
		end
		
		local inputs = {}
		for _, i in ipairs(intermediate) do
			local r = self.rule { i }
			table_append(inputs, r:__build())
		end
		
		self:__buildadditionalchildren()
		scope = scope.next
		return inputs
	end,

 	-- Inputs are outputs --- because __buildchildren has already done the
 	-- necessary work.
 	
 	__outputs = function(self, inputs)
 		return inputs
 	end,

 	-- Building does nothing.
 	
 	__dobuild = function(self, inputs, outputs)
 	end,
}

--- Simple ---------------------------------------------------------------

-- simple is the most common clause, and implements make-like behaviour:
-- the named command is executed in order to rebuild the node.
--
--  * The timestamp is the newest timestamp of its outputs.
--  * Building executes the command.
--  * Its outputs are automatically generated by expanding the templates
--    in the 'outputs' variable.

simple = node {
	class = "file",
 	construct_string_children_with = file,
 	all_children_are_objects = true,
 	
 	__init = function(self, p)
 		node.__init(self, p)
  		
		-- If we're a class, don't verify.
		
		if ((type(p) == "table") and p.class) then
			return
		end

		-- outputs must exist, and must be a table.
		
		if not self.outputs then
			self:__error("must have an outputs template set")
		end
		
		if (type(self.outputs) ~= "table") then
			self:__error("doesn't know what to do with its outputs, which is a ",
				type(self.outputs), " but should be a table")
		end
					
		-- There must be a command which must be a string or table.
		
		if not self.command then
			self:__error("must have a command specified")
		end
		if (type(self.command) == "string") then
			self.command = {self.command}
		end
		if (type(self.command) ~= "table") then
			self:__error("doesn't know what to do with its command, which is a ",
				type(self.command), " but should be a string or a table")
		end
	end,
	
 	-- Outputs are specified manually.
 	
 	__outputs = function(self, inputs)
 		local input
 		if inputs then
 			input = inputs[1]
 		end
 		if not input then
 			input = ""
 		end
 
		self.I = string_gsub(input, "^.*/", "")
		self.I = string_gsub(self.I, "%..-$", "")

		-- Construct an outputs array for use in the cache key. This mirrors
		-- what the final array will be, but the unique ID is going to be 0.
		-- Note that we're overriding %out% here; this is safe, because it
		-- hasn't been set yet when __outputs is called, and is going to be
		-- set to the correct value when this function exits.
		
		self.out = {}
		self.U = 0
		for _, i in ipairs(self.outputs) do
			i = self:__expand(i)
			table_append(self.out, i)
		end
		
		-- Determine the cache key we're going to use.
		
		local cachekey = table_concat(self.command, " && ")
		cachekey = self:__expand(cachekey)
		cachekey = create_intermediate_cache_key(cachekey)

		-- Work out the unique ID.
		--
		-- Note: we're running in the sandbox, so we need to fully qualify
		-- pm.intermediate_cache_dir.
		
		self.U = pm.intermediate_cache_dir..cachekey
		
		-- Construct the real outputs array.
				
 		self.out = {}
 		for _, i in ipairs(self.outputs) do
 			i = self:__expand(i)
			mkcontainerdir(i)
 			table_append(self.out, i)
		end

 		return self.out
 	end,
 	
 	-- Building causes the command to be expanded and invoked. The 'children'
 	-- variable is set to the input files.
 	
 	__dobuild = function(self, inputs, outputs)
		local r = self:__invoke(self.command, inputs, outputs)
		if r then
			if delete_output_files_on_error then
				self:__invoke({"%RM% %out%"})
			end			
			self:__error("failed to build with return code ", r)
		end
 	end,
}

--- End of prologue ---------------------------------------------------------

-- Set a few useful global variables.

RM = "rm -f"
INSTALL = "ln -f"

-- Now we're done, switch out of sandbox mode again. This only works
-- because we made _G local at the top of the file, which makes it
-- lexically scoped rather than looked up via the environment.

setfenv(1, _G)

-- ======================================================================= --
--                          APPLICATION DRIVER                             --
-- ======================================================================= --

-- Parse and process the command line options.

do
	local function do_help(opt)
		message("Prime Mover version ", VERSION, " © 2006-2007 David Given")
		stdout:write([[
Syntax: pm [<options...>] [<targets>]
Options:
   -h    --help        Displays this message.
         --license     List Prime Mover's redistribution license.
   -cX   --cachedir X  Sets the object file cache to directory X.
   -p    --purge       Purges the cache before execution.
                       WARNING: will remove *everything* in the cache dir!
   -fX   --file X      Reads in the pmfile X. May be specified multiple times.
   -DX=Y --define X=Y  Defines variable X to value Y (or true if Y omitted)
   -n    --no-execute  Don't actually execute anything
   -v    --verbose     Be more verbose
   -q    --quiet       Be more quiet
   
If no pmfiles are explicitly specified, 'pmfile' is read.
If no targets are explicitly specified, 'default' is built.
Options and targets may be specified in any order.
]])
		os.exit(0)
	end
	
	local function do_license(opt)
		message("Prime Mover version ", VERSION, " © 2006 David Given")
		stdout:write([[
		
Prime Mover is licensed under the MIT open source license.

Copyright © 2006-2007 David Given

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]])
		os.exit(0)
	end

	local function needarg(opt)
		if not opt then
			usererror("missing option parameter")
		end
	end
	
	local function do_cachedir(opt)
		needarg(opt)
		intermediate_cache_dir = opt
		return 1
	end
	
	local function do_inputfile(opt)
		needarg(opt)
		table_append(input_files, opt)
		return 1
	end
	
	local function do_purgecache(opt)
		purge_intermediate_cache = true
		return 0
	end
	
	local function do_define(opt)
		needarg(opt)
		
		local s, e, key, value = string_find(opt, "^([^=]*)=(.*)$")
		if not key then
			key = opt
			value = true
		end
		
		sandbox[key] = value
		return 1
	end
	
	local function do_no_execute(opt)
		no_execute = true
		return 0
	end
	
	local function do_verbose(opt)
		verbose = true
		return 0
	end
	
	local function do_quiet(opt)
		quiet = true
		return 0
	end
	
	local argmap = {
		["h"]           = do_help,
		["help"]        = do_help,
		["c"]           = do_cachedir,
		["cachedir"]    = do_cachedir,
		["p"]           = do_purgecache,
		["purge"]       = do_purgecache,
		["f"]           = do_inputfile,
		["file"]        = do_inputfile,
		["D"]           = do_define,
		["define"]      = do_define,
		["n"]           = do_no_execute,
		["no-execute"]  = do_no_execute,
		["v"]           = do_verbose,
		["verbose"]     = do_verbose,
		["q"]           = do_quiet,
		["quiet"]       = do_quiet,
		["license"]     = do_license,
	}
	
	-- Called on an unrecognised option.
	
	local function unrecognisedarg(arg)
		usererror("unrecognised option '", arg, "' --- try --help for help")
	end
	
	-- Do the actual argument parsing.
	
	for i = 1, table_getn(arg) do
		local o = arg[i]
		local op
		
		if (string_byte(o, 1) == 45) then
			-- This is an option.
			if (string_byte(o, 2) == 45) then
				-- ...with a -- prefix.
				o = string_sub(o, 3)
				local fn = argmap[o]
				if not fn then
					unrecognisedarg("--"..o)
				end
				local op = arg[i+1]
				i = i + fn(op)
			else
				-- ...without a -- prefix.
				local od = string_sub(o, 2, 2)
				local fn = argmap[od]
				if not fn then
					unrecognisedarg("-"..od)
				end
				op = string_sub(o, 3)
				if (op == "") then
					op = arg[i+1]
					i = i + fn(op)
				else
					fn(op)
				end
			end
		else
			-- This is a target name.
			table_append(targets, o)
		end	
	end
	
	-- Option fallbacks.
	
	if (table_getn(input_files) == 0) then
		input_files = {"pmfile"}
	end
	
	if (table_getn(targets) == 0) then
		targets = {"default"}
	end
end

-- Load any input files.

for _, i in ipairs(input_files) do
	sandbox.include(i, unpack(arg))
end

-- Set up the intermediate cache.

if purge_intermediate_cache then
	create_intermediate_cache()
else
	load_intermediate_cache()
end

-- Build any targets.

for _, i in ipairs(targets) do
	local o = sandbox[i]
	if not o then
		usererror("don't know how to build '", i, "'")
	end
	if ((type(o) ~= "table") and not o.class) then
		usererror("'", i, "' doesn't seem to be a valid target")
	end

	xpcall(
		function()
			o:__build()
		end,
		function(e)
			message("rule engine execution error --- traceback follows:")
			traceback(e)
		end
	)
end
