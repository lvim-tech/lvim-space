local M = {}

M.merge = function(t1, t2)
	for k, v in pairs(t2) do
		if (type(v) == "table") and (type(t1[k] or false) == "table") then
			if M.is_array(t1[k]) then
				t1[k] = M.concat(t1[k], v)
			else
				M.merge(t1[k], t2[k])
			end
		else
			t1[k] = v
		end
	end
	return t1
end

M.concat = function(t1, t2)
	for i = 1, #t2 do
		table.insert(t1, t2[i])
	end
	return t1
end

M.is_array = function(t)
	local i = 0
	for _ in pairs(t) do
		i = i + 1
		if t[i] == nil then
			return false
		end
	end
	return true
end

M.has_permission = function(path)
	local cmd = string.format('[ -d "%s" ] && [ -r "%s" ] && [ -x "%s" ]', path, path, path)
	local ok = os.execute(cmd)
	return ok == 0
end

M.to_superscript = function(num)
	local smallNumbers = {
		"\u{2070}",
		"\u{00b9}",
		"\u{00b2}",
		"\u{00b3}",
		"\u{2074}",
		"\u{2075}",
		"\u{2076}",
		"\u{2077}",
		"\u{2078}",
		"\u{2079}",
	}
	local numberStr = tostring(num)
	local numberToShow = ""
	for i = 1, #numberStr do
		local digit = tonumber(numberStr:sub(i, i))
		if digit then
			numberToShow = numberToShow .. smallNumbers[digit + 1]
		end
	end
	return numberToShow
end

return M
