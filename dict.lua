local Dict = { SIGNATURE = 'PersistentDictionary' }

-- KEY, VALUE, LEFT, RIGHT, LEVEL = 1, 2, 3, 4, 5

local NIL = {false,false,false,false,0}

local function skew( node )
	if node ~= NIL then
		local lnode = node[3]
		if lnode ~= NIL then
			local level = node[5]
			local llevel = lnode[5]
			if level == llevel then
				local r = {node[1], node[2], lnode[4], node[4], level}
				return {lnode[1], lnode[2], lnode[3], r, level}
			end
		end
	end
	return node
end

local function split( node )
	if node ~= NIL then
		local rnode = node[4]
		if rnode ~= NIL then
			local rrnode = rnode[4]
			if rrnode ~= NIL then
				local level = node[5]
				local rrlevel = rrnode[5]
				if level == rrlevel then
					local l = {node[1], node[2], node[3], rnode[3], level}
					return {rnode[1], rnode[2], l, rrnode, level+1}
				end
			end
		end
	end
	return node
end

local function rebalance( node )
	return split( skew ( node ))
end

local set

function Dict.make( ... )
	local self = {
		type = Dict.SIGNATURE,
		size = 0,
		root = NIL
	}
	if ... then
		for k, v in ... do
			self = set( self, k, v )
		end
	end
	return self
end

function Dict.get( self, key )
	local node = self.root
	while node ~= NIL do
		local nodekey = node[1]	
		if key == nodekey then
			return node[2]
		elseif key < nodekey then
			node = node[3]
		else
			node = node[4]
		end
	end
end

local function setnode( node, key, value )
	if node == NIL then
		return {key, value, NIL, NIL, 1}
	else
		local nodekey = node[1]
		if key == nodekey then
			return {key, value, node[3], node[4], node[5]}
		elseif key < nodekey then
			return rebalance{nodekey, node[2], setnode( node[3], key, value ), node[4], node[5]}
		else
			return rebalance{nodekey, node[2], node[3], setnode( node[4], key, value ), node[5]}
		end
	end
end

local get = Dict.get

function Dict.set( self, key, value )
	local old = get( self, key )
	if old ~= value then
		local dsize = value == nil and -1 or 1
		return {
			type = Dict.SIGNATURE,
			root = setnode( self.root, key, value ),
			size = self.size + dsize
		}
	else
		return self
	end
end

set = Dict.set

function Dict.remove( self, key )
	return set( self, key )
end

local function iteratepairs( state )
	if state ~= NIL then
		iteratepairs( state[3] )
		if state[2] ~= nil then
			coroutine.yield( state[1], state[2] )
		end
		iteratepairs( state[4] )
	end
end

function Dict.pairs( self )
	return coroutine.wrap( iteratepairs ), self.root
end

function Dict.len( self )
	return self.size
end

return Dict
