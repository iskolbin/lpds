local Vec = { SIGNATURE = 'PersistentVector' }

local floor, assert, setmetatable = math.floor, _G.assert, _G.setmetatable
local unpack = table.unpack or _G.unpack

local bit = _G.bit or _G.bit32 or _VERSION >= 'Lua 5.3' and {
	lshift = load[[return function( a, b ) return (a << b) & 0xffffffff end]](),
	arshift = load[[return function( a, b ) return (a >> b) & 0xffffffff end]](),
	xor = load[[return function( a, b ) return (a ~ b) end]](),
} or {
	lshift = function( a, b )
		return floor( a * 2^b ) % 2^32
	end,
	arshift = function( a, b )
		local z = floor(a % 2^32 / 2^b)
		if a >= 0x80000000 then
			z = z + floor( (2^b-1) * 2^(32-b) ) % 2^32
		end
		return z
	end,
	bxor = (function()
	local function memoize(f)
		local mt = {}
		local t = setmetatable({}, mt)
		function mt.__index(_,k)
			local v = f(k); t[k] = v
			return v
		end
		return t
	end

	local function make_bitop_uncached(t, m)
		local function bitop(a, b)
			local res,p = 0,1
			while a ~= 0 and b ~= 0 do
				local am, bm = a%m, b%m
				res = res + t[am][bm]*p
				a = (a - am) / m
				b = (b - bm) / m
				p = p*m
			end
			res = res + (a+b)*p
			return res
		end
		return bitop
	end

	local function make_bitop(t)
		local op1 = make_bitop_uncached(t,2^1)
		local op2 = memoize(function(a)
			return memoize(function(b)
				return op1(a, b)
			end)
		end)
		return make_bitop_uncached(op2, 2^(t.n or 1))
	end

	return make_bitop {[0]={[0]=0,[1]=1},[1]={[0]=1,[1]=0}, n=4}
	end)()
}

local shr = bit.arshift
local shl = bit.lshift
local xor = bit.bxor

local EMPTY_TAIL = {}

local function newVec( size, shift, root, tail )
	return {
		type = Vec.SIGNATURE,
		size = size,
		shift = shift,
		root = root,
		tail = tail,
	}
end

local __transientpush

function Vec.make( ... )
	local result = newVec( 0, 0, nil, EMPTY_TAIL )
	if ... then
		for _, v in ... do
			__transientpush( result, v )
		end
	end
	return result
end

local function copy( array, from, to )
	return {unpack( array, from, to )}
end

local function tailoffset( self )
	return 32 * floor((self.size-1) * (1/32))
end

local function tailsize( self )
	return self.size == 0 and 0 or (((self.size-1) % 32) + 1)
end

function Vec.set( self, i, val )
	assert( i >= 1 and i <= self.size, 'Index out of bounds' )

	if i > tailoffset( self ) then
		local newtail = copy( self.tail )
		newtail[(i-1) % 32 + 1] = val
		return newVec( self.size, self.shift, self.root, newtail )
	else
		local newroot = copy( self.root )
		local node = newroot
		for level = self.shift, 1, -5 do
			local subidx = shr(i-1, level) % 32 + 1
			local child = copy( node[subidx] )
			node[subidx] = child
			node = child
		end
		node[(i-1) % 32 + 1] = val
		return newVec( self.size, self.shift, newroot, self.tail )
	end
end

function Vec.get( self, i )
	assert( i >= 1 and i <= self.size, 'Index out of bounds' )

	if i > tailoffset( self ) then
		return self.tail[(i-1) % 32 + 1]
	else
		local node = self.root
		for level = self.shift, 1, -5 do
			node = node[shr(i-1,level) % 32 + 1]
		end
		return node[(i-1) % 32 + 1]
	end
end

local function newpath( levels, tail )
	local topNode = tail
	for _ = levels, 1, -5 do
		topNode = {topNode}
	end
	return topNode
end

local function pushleaf( shift, i, root, tail, transient )
	local newroot = transient and root or copy( root )
	local node = newroot
	for level = shift, 6, -5 do
		local subidx = shr( i-1, level ) % 32 + 1
		local child = node[subidx]
		if child == nil then
			node[subidx] = newpath( level-5, tail )
			return newroot
		end
		child = transient and child or copy( child )
		node[subidx] = child
		node = child
	end
	node[shr( i-1, 5 ) % 32 + 1] = tail
	return newroot
end

function Vec.insert( self, val )
	local ts = tailsize( self )
	local size, shift = self.size, self.shift

	if ts ~= 32 then
		local newtail = copy( self.tail )
		newtail[#newtail+1] = val
		return newVec(size+1, shift, self.root, newtail )
	else
		if self.size == 32 then
			return newVec( size+1, 0, self.tail, {val} )
		elseif shr( size, 5 ) > shl( 1, shift ) then
			return newVec( size+1, shift + 5, {self.root, newpath( shift, self.tail)}, {val} )
		else
			return newVec( size+1, shift, pushleaf( shift, size-1, self.root, self.tail ), {val} )
		end
	end
end

local function lowertrie( self, transient )
	local lowerShift = self.shift - 5
	local node = self.root[2]
	for _ = lowerShift, 1, -5 do
		node = node[1]
	end
	if transient then
		self.root, self.tail, self.size = self.root[1], node, self.size-1
		return self
	else
		return newVec( self.size-1, lowerShift, self.root[1], node )
	end
end

local function poptrie( self, transient )
	local newsize = self.size - 33
	local diverges = xor( newsize , newsize - 1 )
	local diverged = false
	local newroot = transient and self.root or copy( self.root )
	local node = newroot
	for level = self.shift, 1, -5 do
		local subidx = shr( newsize-1, level ) % 32 + 1
		local child = node[subidx]
		if diverged then
			node = child
		elseif shr( diverges, level ) ~= 0 then
			diverged = true
			node[subidx] = nil
			node = child
		else
			child = transient and child or copy( child )
			node[subidx] = child
			node = child
		end
	end
	if transient then
		self.tail, self.size = node, self.size-1
		return self
	else
		return newVec( self.size-1, self.shift, newroot, node )
	end
end

function Vec.remove( self )
	local size = self.size
	assert( size > 0, 'Vector is empty' )

	if ((size-1) % 32) >= 0 then
		return newVec( size-1, self.shift, self.root, copy( self.tail, 1, #self.tail-1 ))
	else
		if size == 33 then
			return newVec( 32, 0, nil, self.tail )
		elseif size - 33 == shl( 1, self.shift ) then
			return lowertrie( self )
		else
			return poptrie( self )
		end
	end
end

function Vec.__transientset( self, i, val )
	if i > tailoffset( self ) then
		self.tail[(i-1) % 32 + 1] = val
	else
		local node = self.root
		for level = self.shift, 1, -5 do
			node = node[shr(i-1, level) % 32 + 1]
		end
		node[(i-1) % 32 + 1] = val
	end
	return self
end

function Vec.__transientpush( self, val )
	local ts = tailsize( self )
	local size, shift = self.size, self.shift

	if ts ~= 32 then
		self.tail[#self.tail+1] = val
	else
		if self.size == 32 then
			self.root = self.tail
		elseif shr( size, 5 ) > shl( 1, shift ) then
			self.root, self.shift = newpath( shift, self.tail ), shift + 5
		else
			self.root = pushleaf( shift, size-1, self.root, self.tail, true )
		end
		self.tail = {val}
	end
	self.size = self.size + 1
	return self
end

__transientpush = Vec.__transientpush

function Vec.__transientpop( self )
	local size = self.size
	assert( size > 0, 'Vector is empty' )

	if ((size-1) % 32) >= 0 then
		self.tail[#self.tail], self.size = nil, size - 1
	else
		if size == 33 then
			self.root, self.size = nil, 32
		elseif size - 33 == shl( 1, self.shift ) then
			lowertrie( self, true )
		else
			poptrie( self, true )
		end
	end
	return self
end

function Vec.len( self )
	return self.size
end

function Vec.ipairs( self )
	local size = self.size
	local shift = self.shift
	local tail = self.tail
	local jump = 33
	local stack
	local leaf
	local toffset = tailoffset( self )

	if size <= 32 then
		leaf = self.tail
	elseif size <= 64 then
		leaf = self.root
	else
		local m = floor( shift/5 )
		stack = {}
		for i = 1, m do
			stack[i] = {}
		end
		stack[m] = self.root
		for i = m-1, 1, -1 do
			stack[i] = stack[i+1][1]
		end
		leaf = stack[1][1]
	end

	return function( _, i )
		i = (i or 0) + 1
		if i <= size then
			if i == jump then
				if i >= toffset then
					leaf = tail
				else
					jump = jump + 32
					local diff = xor( i, i-1 )
					local level = 10
					local stackupd = 0
					while shr( diff, level ) ~= 0 do
						stackupd = stackupd + 1
						level = level + 5
					end
					level = level - 5
					while stackupd > 0 do
						stack[stackupd] = stack[stackupd][shr(i-1,level) % 32 + 1]
						stackupd = stackupd - 1
						level = level - 5
					end
					leaf = stack[1][shr(i-1,5) % 32 + 1]
				end
			end
			return i, leaf[(i-1) % 32 + 1]
		end
	end
end

Vec.pairs = Vec.ipairs

return Vec
