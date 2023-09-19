local computer = require('computer')
local blueDebug = {}

function blueDebug.print(tbl)
	print(blueDebug.format(tbl))
end

function blueDebug.format(value, indentSize)
	if not indentSize then indentSize = 0 end

	if type(value) == "table" then
		local str = "{\n"
		local isArr = isArray(value)
		if isArr then
			for i, v in ipairs(value) do
				local valueStr = indent(indentSize + 1) .. blueDebug.format(v)

				str = str .. valueStr
				-- last item
				if next(value, i) ~= nil then
					str = str .. ','
				end
				str = str .. '\n'
			end
		else
			local keys = {}
			for key in pairs(value) do
				table.insert(keys, key)
			end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for i, k in ipairs(keys) do
				local v = value[k]
				local keyStr = ''
				if (type(k) == 'string' and isVariableName(k)) then
					keyStr = tostring(k)
				else
					keyStr = '[' .. blueDebug.format(k) .. ']'
				end

				local valueStr = blueDebug.format(v, indentSize + 1)

				str = str .. indent(indentSize + 1) .. keyStr .. " = " .. valueStr
				-- last item
				if next(keys, i) ~= nil then
					str = str .. ','
				end
				str = str .. '\n'
			end
		end

		str = str .. indent(indentSize) .. "}"
		return str
	else
		if type(value) == 'string' then
			return '"' .. value .. '"'
		else
			return tostring(value)
		end
	end
end

function indent(indentSize)
	return string.rep("  ", indentSize)
end

function isVariableName(str)
	-- Check if the string is not empty
	if #str == 0 then
		return false
	end

	-- Check if the first character is a letter or an underscore
	local firstChar = string.sub(str, 1, 1)
	if not (string.match(firstChar, "[a-zA-Z]") or firstChar == "_") then
		return false
	end

	-- Check the rest of the characters
	for i = 2, #str do
		local char = string.sub(str, i, i)
		if not (string.match(char, "[a-zA-Z0-9]") or char == "_") then
			return false
		end
	end

	-- If all checks passed, the string is a valid variable name
	return true
end

function isArray(table)
	if type(table) ~= "table" then
		return false
	end

	local maxIndex = 0
	for key, _ in pairs(table) do
		if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
			return false
		end
		maxIndex = math.max(maxIndex, key)
	end

	return maxIndex == #table
end

local timers = {}

function blueDebug.time(label)
	assert(type(label) == 'string', 'Expected string, got ' .. type(label))
	timers[label] = computer.uptime()
end

function blueDebug.timeEnd(label)
	assert(type(label) == 'string', 'Expected string, got ' .. type(label))
	assert(timers[label] ~= nil, 'Timer "' .. label .. '" does not exist.')
	local formattedTime
	local time = computer.uptime() - timers[label]
	if time > 1 then
		formattedTime = blueDebug.round(time, 3) .. 's'
	else
		-- formattedTime = string.format("%.2f", (time * 1000)) .. 'ms'
		formattedTime = blueDebug.round(time * 1000, 2) .. 'ms'
	end
	print(label .. ': ' .. formattedTime)
end

function blueDebug.round(number, decimalPlaces)
	local multiplier = 10 ^ decimalPlaces
	return math.floor(number * multiplier + 0.5) / multiplier
end

function blueDebug.require(packageName)
	package.loaded[packageName] = nil
	return require(packageName)
end

-- local myTable = {
-- 	name = "John",
-- 	age = 30,
-- 	address = {
-- 		street = "123 Main St",
-- 		city = "Anytown",
-- 	},
-- 	hobbies = { "Reading", "Gaming", "Cooking" },
-- 	[1] = true,
-- 	["hello "] = false
-- }

-- customDebug.print(myTable)

return blueDebug
