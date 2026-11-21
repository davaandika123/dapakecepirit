local url = "https://raw.githubusercontent.com/username/repo/main/menu.lua"

-- Fungsi penarik script khusus Arceus NEO
local ok, code = pcall(function()
    return game:HttpGet(url, true)
end)

if ok and code then
    if getcustomasset then
        -- Simpen ke file lokal dulu
        writefile("temp_menu.lua", code)
        -- Jalanin lewat custom asset (bypass blokir loadstring)
        getcustomasset("temp_menu.lua")
    else
        -- Fallback kalau executor support loadstring standar
        if loadstring then
            loadstring(code)()
        else
            print("Executor lu ga support loadstring atau getcustomasset.")
        end
    end
else
    print("Gagal download script dari GitHub.")
end