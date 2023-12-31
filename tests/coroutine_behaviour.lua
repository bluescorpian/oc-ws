local function subYielding()
	local function subFunction()
		if coroutine.isyieldable() then coroutine.yield('Yield from sub function') end
		print('Execution resumed')
	end
	local co = coroutine.create(function()
		subFunction()
	end)

	print('Coroutine Test:')
	print(coroutine.resume(co))
	print(coroutine.resume(co))
	print('Main Thread Test:')
	print(subFunction())
end

local function wrappedCoroutines()
	local co = coroutine.wrap(function()
		print("Coroutine started")
		coroutine.yield()
		print("Coroutine resumed")
	end)

	co()
	co()
	co()
end

local function coroutineArguments()
	local co = coroutine.create(function(test)
		print('Argument: ' .. test)
		print('Yield: ' .. coroutine.yield())
		return 'Returning Hello'
	end)
	coroutine.resume(co, 'Hello World!')
	local success, value = coroutine.resume(co, 'Hotdog!')
	print('Return: ' .. value)
end

local function coroutineErrors()
	local co = coroutine.create(function()
		error('Test error')
	end)

	print(coroutine.resume(co))
end

local function coroutineReturns()
	local co = coroutine.create(function()
		coroutine.yield('Yield hello world')
		return 'Hello World!'
	end)
	print(coroutine.resume(co))
	print(coroutine.resume(co))
	print(coroutine.resume(co))
end

-- coroutineArguments()
-- wrappedCoroutines()
-- subYielding()
-- coroutineErrors()
coroutineReturns()
