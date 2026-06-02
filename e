task.spawn(function()
    local load = require(game.ReplicatedStorage:WaitForChild("Fsys")).load

    set_thread_identity(2)
    local clientData = load("ClientData")
    local items = load("KindDB")
    local router = load("RouterClient")
    local downloader = load("DownloadClient")
    local animationManager = load("AnimationManager")
    local petRigs = load("new:PetRigs")
    set_thread_identity(8)

    local petModels = {}
    local pets = {}
    local equippedPet = nil
    local mountedPet = nil
    local currentMountTrack = nil

    -- ═══════════════════════════════════════════
    --  ORIGINAL PET LOGIC (untouched)
    -- ═══════════════════════════════════════════
    local function updateData(key, action)
        local data = clientData.get(key)
        local clonedData = table.clone(data)
        clientData.predict(key, action(clonedData))
    end

    local function getUniqueId()
        local HttpService = game:GetService("HttpService")
        return HttpService:GenerateGUID(false)
    end

    local function getPetModel(kind)
        if petModels[kind] then return petModels[kind] end
        local streamed = downloader.promise_download_copy("Pets", kind):expect()
        petModels[kind] = streamed
        return streamed
    end

    local function createPet(id, properties)
        local uniqueId = getUniqueId()
        local pet = nil
        set_thread_identity(2)
        updateData("inventory", function(inventory)
            local newPets = table.clone(inventory.pets)
            local item = items[id]
            pet = {
                unique = uniqueId, category = "pets", id = id,
                kind = item.kind, newness_order = 0, properties = properties,
            }
            newPets[uniqueId] = pet
            inventory.pets = newPets
            return inventory
        end)
        set_thread_identity(8)
        pets[uniqueId] = {data = pet, model = nil}
        return pet
    end

    local function neonify(model, entry)
        local petModel = model:FindFirstChild("PetModel")
        if not petModel then return end
        for neonPart, configuration in pairs(entry.neon_parts) do
            local trueNeonPart = petRigs.get(petModel).get_geo_part(petModel, neonPart)
            trueNeonPart.Material = configuration.Material
            trueNeonPart.Color = configuration.Color
        end
    end

    local function addPetWrapper(wrapper)
        updateData("pet_char_wrappers", function(petWrappers)
            wrapper.unique = #petWrappers + 1
            wrapper.index = #petWrappers + 1
            petWrappers[#petWrappers + 1] = wrapper
            return petWrappers
        end)
    end

    local function addPetState(state)
        updateData("pet_state_managers", function(petStates)
            petStates[#petStates + 1] = state
            return petStates
        end)
    end

    local function findIndex(array, finder)
        for index, value in pairs(array) do
            if finder(value, index) then return index end
        end
        return nil
    end

    local function removePetWrapper(uniqueId)
        updateData("pet_char_wrappers", function(petWrappers)
            local index = findIndex(petWrappers, function(wrapper) return wrapper.pet_unique == uniqueId end)
            if not index then return petWrappers end
            table.remove(petWrappers, index)
            for wrapperIndex, wrapper in pairs(petWrappers) do
                wrapper.unique = wrapperIndex
                wrapper.index = wrapperIndex
            end
            return petWrappers
        end)
    end

    local function clearPetState(uniqueId)
        local pet = pets[uniqueId]
        if not pet or not pet.model then return end
        updateData("pet_state_managers", function(states)
            local index = findIndex(states, function(state) return state.char == pet.model end)
            if not index then return states end
            local clonedStates = table.clone(states)
            clonedStates[index] = table.clone(clonedStates[index])
            clonedStates[index].states = {}
            return clonedStates
        end)
    end

    local function setPetState(uniqueId, id)
        local pet = pets[uniqueId]
        if not pet or not pet.model then return end
        updateData("pet_state_managers", function(states)
            local index = findIndex(states, function(state) return state.char == pet.model end)
            if not index then return states end
            local clonedStates = table.clone(states)
            clonedStates[index] = table.clone(clonedStates[index])
            clonedStates[index].states = {{id = id}}
            return clonedStates
        end)
    end

    local function attachPlayerToPet(pet)
        local character = game.Players.LocalPlayer.Character
        if not character or not character.PrimaryPart then return false end
        local ridePosition = pet:FindFirstChild("RidePosition", true)
        if not ridePosition then return false end
        local sourceAttachment = Instance.new("Attachment")
        sourceAttachment.Parent = ridePosition
        sourceAttachment.Position = Vector3.new(0, 1.237, 0)
        sourceAttachment.Name = "SourceAttachment"
        local stateConnection = Instance.new("RigidConstraint")
        stateConnection.Name = "StateConnection"
        stateConnection.Attachment0 = sourceAttachment
        stateConnection.Attachment1 = character.PrimaryPart.RootAttachment
        stateConnection.Parent = character
        return true
    end

    local function clearPlayerState()
        updateData("state_manager", function(state)
            local clonedState = table.clone(state)
            clonedState.states = {}
            clonedState.is_sitting = false
            return clonedState
        end)
    end

    local function setPlayerState(id)
        updateData("state_manager", function(state)
            local clonedState = table.clone(state)
            clonedState.states = {{id = id}}
            clonedState.is_sitting = true
            return clonedState
        end)
    end

    local function removePetState(uniqueId)
        local pet = pets[uniqueId]
        if not pet or not pet.model then return end
        updateData("pet_state_managers", function(petStates)
            local index = findIndex(petStates, function(state) return state.char == pet.model end)
            if not index then return petStates end
            table.remove(petStates, index)
            return petStates
        end)
    end

    local function unmount(uniqueId)
        local pet = pets[uniqueId]
        if not pet or not pet.model then return end
        if currentMountTrack then currentMountTrack:Stop() currentMountTrack:Destroy() end
        local sourceAttachment = pet.model:FindFirstChild("SourceAttachment", true)
        if sourceAttachment then sourceAttachment:Destroy() end
        if game.Players.LocalPlayer.Character then
            for _, descendant in pairs(game.Players.LocalPlayer.Character:GetDescendants()) do
                if descendant:IsA("BasePart") and descendant:GetAttribute("HaveMass") then
                    descendant.Massless = false
                end
            end
        end
        clearPetState(uniqueId)
        clearPlayerState()
        pet.model:ScaleTo(1)
        mountedPet = nil
    end

    local function mount(uniqueId, playerState, petState)
        local pet = pets[uniqueId]
        if not pet or not pet.model then return end
        local player = game.Players.LocalPlayer
        if not player.Character or not player.Character.PrimaryPart then return end
        mountedPet = uniqueId
        setPetState(uniqueId, petState)
        setPlayerState(playerState)
        pet.model:ScaleTo(2)
        attachPlayerToPet(pet.model)
        currentMountTrack = player.Character.Humanoid.Animator:LoadAnimation(animationManager.get_track("PlayerRidingPet"))
        player.Character.Humanoid.Sit = true
        for _, descendant in pairs(player.Character:GetDescendants()) do
            if descendant:IsA("BasePart") and descendant.Massless == false then
                descendant.Massless = true
                descendant:SetAttribute("HaveMass", true)
            end
        end
        currentMountTrack:Play()
    end

    local function fly(uniqueId) mount(uniqueId, "PlayerFlyingPet", "PetBeingFlown") end
    local function ride(uniqueId) mount(uniqueId, "PlayerRidingPet", "PetBeingRidden") end

    local function unequip(item)
        local pet = pets[item.unique]
        if not pet or not pet.model then return end
        unmount(item.unique)
        removePetWrapper(item.unique)
        removePetState(item.unique)
        pet.model:Destroy()
        pet.model = nil
        equippedPet = nil
    end

    local function equip(item)
        if equippedPet then unequip(equippedPet) end
        local petModel = getPetModel(item.kind):Clone()
        petModel.Parent = workspace
        pets[item.unique].model = petModel
        if item.properties.neon or item.properties.mega_neon then
            neonify(petModel, items[item.kind])
        end
        equippedPet = item
        addPetWrapper({
            char = petModel, mega_neon = item.properties.mega_neon, neon = item.properties.neon,
            player = game.Players.LocalPlayer, entity_controller = game.Players.LocalPlayer,
            controller = game.Players.LocalPlayer, rp_name = item.properties.rp_name or "",
            pet_trick_level = item.properties.pet_trick_level, pet_unique = item.unique,
            pet_id = item.id,
            location = {full_destination_id = "housing", destination_id = "housing", house_owner = game.Players.LocalPlayer},
            pet_progression = {friendship_level = item.properties.friendship_level, age = item.properties.age, percentage = 0},
            are_colors_sealed = false, is_pet = true,
        })
        addPetState({
            char = petModel, player = game.Players.LocalPlayer, store_key = "pet_state_managers",
            is_sitting = false, chars_connected_to_me = {}, states = {},
        })
    end

    local oldGet = router.get

    local function createRemoteFunctionMock(callback)
        return {InvokeServer = function(_, ...) return callback(...) end}
    end
    local function createRemoteEventMock(callback)
        return {FireServer = function(_, ...) return callback(...) end}
    end

    local equipRemote = createRemoteFunctionMock(function(uniqueId, metadata)
        local pet = pets[uniqueId]
        if not pet then return end
        equip(pet.data)
        return true, {action = "equip", is_server = true}
    end)

    local unequipRemote = createRemoteFunctionMock(function(uniqueId)
        local pet = pets[uniqueId]
        if not pet then return end
        unequip(pet.data)
        return true, {action = "unequip", is_server = true}
    end)

    local rideRemote = createRemoteFunctionMock(function(item) ride(item.pet_unique) end)
    local flyRemote = createRemoteFunctionMock(function(item) fly(item.pet_unique) end)
    local unmountRemoteFunction = createRemoteFunctionMock(function() unmount(mountedPet) end)
    local unmountRemoteEvent = createRemoteEventMock(function() unmount(mountedPet) end)

    router.get = function(name)
        if name == "ToolAPI/Equip" then return equipRemote end
        if name == "ToolAPI/Unequip" then return unequipRemote end
        if name == "AdoptAPI/RidePet" then return rideRemote end
        if name == "AdoptAPI/FlyPet" then return flyRemote end
        if name == "AdoptAPI/ExitSeatStatesYield" then return unmountRemoteFunction end
        if name == "AdoptAPI/ExitSeatStates" then return unmountRemoteEvent end
        return oldGet(name)
    end

    for _, charWrapper in pairs(clientData.get("pet_char_wrappers")) do
        oldGet("ToolAPI/Unequip"):InvokeServer(charWrapper.pet_unique)
    end

    local Loads = require(game.ReplicatedStorage.Fsys).load
    local InventoryDB = Loads("InventoryDB")

    local function GetPetByName(name)
        for i, v in pairs(InventoryDB.pets) do
            if v.name:lower() == name:lower() then
                return v.id
            end
        end
        return false
    end

    -- ═══════════════════════════════════════════════════════════
    --   ┌──────────────────────────────────────────────────┐
    --   │   UI — macOS Dark · 3 Tabs · Live Theming         │
    --   │   Main · Custom · Settings   (Mobile Ready)       │
    --   └──────────────────────────────────────────────────┘
    -- ═══════════════════════════════════════════════════════════
    local Players          = game:GetService("Players")
    local TweenService     = game:GetService("TweenService")
    local UserInputService = game:GetService("UserInputService")
    local Workspace        = game:GetService("Workspace")

    local LocalPlayer = Players.LocalPlayer
    local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
    local Camera      = Workspace.CurrentCamera

    for _, g in ipairs(PlayerGui:GetChildren()) do
        if g.Name == "PetSpawnerGUI" or g.Name == "PetSpawnerReopen" or g.Name == "PetSpawnerLoading" then g:Destroy() end
    end

    -- ── Click sound ──
    local SoundService = game:GetService("SoundService")
    local clickSound = Instance.new("Sound")
    clickSound.SoundId = "rbxassetid://135366639238389"
    clickSound.Volume = 0.5
    clickSound.Parent = SoundService
    local function playClick()
        -- restart from the top so rapid clicks each play
        clickSound.TimePosition = 0
        clickSound:Play()
    end

    -- ── Static palette ──
    local C = {
        bg        = Color3.fromRGB(11, 11, 16),
        bgGrad    = Color3.fromRGB(7, 7, 12),
        panel     = Color3.fromRGB(16, 16, 22),
        card      = Color3.fromRGB(22, 22, 30),
        cardHov   = Color3.fromRGB(28, 28, 40),
        cardGradA = Color3.fromRGB(26, 26, 36),
        cardGradB = Color3.fromRGB(20, 20, 28),
        tb        = Color3.fromRGB(20, 20, 28),
        tbGradA   = Color3.fromRGB(28, 28, 38),
        tbGradB   = Color3.fromRGB(18, 18, 26),
        border    = Color3.fromRGB(42, 42, 62),
        borderHov = Color3.fromRGB(85, 85, 125),
        text      = Color3.fromRGB(234, 234, 248),
        muted     = Color3.fromRGB(112, 112, 142),
        dim       = Color3.fromRGB(56, 56, 76),
        off       = Color3.fromRGB(32, 32, 48),
        white     = Color3.fromRGB(255, 255, 255),
        dotR      = Color3.fromRGB(255, 95, 87),
        dotY      = Color3.fromRGB(255, 189, 46),
        dotG      = Color3.fromRGB(40, 200, 64),
        inputBg   = Color3.fromRGB(18, 18, 26),
        green     = Color3.fromRGB(48, 210, 148),
        red       = Color3.fromRGB(248, 90, 90),
        amber     = Color3.fromRGB(245, 180, 30),
    }

    -- ── Accent presets (live-swappable) ──
    local ACCENTS = {
        {name = "Purple", base = Color3.fromRGB(120, 56, 235), dim = Color3.fromRGB(34, 20, 76),  light = Color3.fromRGB(170, 142, 255)},
        {name = "Crimson",base = Color3.fromRGB(235, 60, 75),  dim = Color3.fromRGB(60, 16, 22),  light = Color3.fromRGB(255, 140, 150)},
        {name = "Cyan",   base = Color3.fromRGB(40, 175, 235), dim = Color3.fromRGB(12, 42, 62),  light = Color3.fromRGB(130, 210, 255)},
        {name = "Green",  base = Color3.fromRGB(40, 200, 140), dim = Color3.fromRGB(12, 50, 38),  light = Color3.fromRGB(120, 240, 185)},
        {name = "Amber",  base = Color3.fromRGB(245, 175, 30), dim = Color3.fromRGB(54, 38, 8),   light = Color3.fromRGB(255, 215, 110)},
        {name = "Pink",   base = Color3.fromRGB(235, 72, 162), dim = Color3.fromRGB(58, 16, 42),  light = Color3.fromRGB(255, 150, 210)},
        {name = "Blue",   base = Color3.fromRGB(52, 116, 245), dim = Color3.fromRGB(14, 30, 70),  light = Color3.fromRGB(142, 178, 255)},
        {name = "Teal",   base = Color3.fromRGB(18, 196, 184), dim = Color3.fromRGB(8, 48, 46),   light = Color3.fromRGB(132, 240, 232)},
        {name = "Orange", base = Color3.fromRGB(245, 128, 34), dim = Color3.fromRGB(52, 28, 8),   light = Color3.fromRGB(255, 180, 118)},
        {name = "Lime",   base = Color3.fromRGB(150, 212, 46), dim = Color3.fromRGB(40, 54, 12),  light = Color3.fromRGB(206, 246, 136)},
        {name = "Magenta",base = Color3.fromRGB(214, 52, 222), dim = Color3.fromRGB(50, 14, 52),  light = Color3.fromRGB(236, 152, 240)},
        {name = "Coral",  base = Color3.fromRGB(250, 116, 104),dim = Color3.fromRGB(56, 22, 20),  light = Color3.fromRGB(255, 172, 162)},
    }
    local ACCENT = {
        base  = ACCENTS[1].base,
        dim   = ACCENTS[1].dim,
        light = ACCENTS[1].light,
    }
    local gradientsEnabled = true
    local gradStrength = 0.5  -- 0 = subtle, 1 = strong accent tint (Settings slider)

    -- The window background gradient. Both stops scale with gradStrength: at 0% it's
    -- basically solid dark, at 100% the whole window is a bold accent wash.
    local function accentBg()        -- bright corner: black -> full accent
        return Color3.fromRGB(8, 8, 13):Lerp(ACCENT.base, math.clamp(gradStrength, 0, 1))
    end
    local function accentBgBottom()  -- dark corner: black -> medium accent
        local botStrong = ACCENT.dim:Lerp(ACCENT.base, 0.5)
        return Color3.fromRGB(8, 8, 13):Lerp(botStrong, math.clamp(gradStrength, 0, 1))
    end
    -- top glow opacity also tracks strength (fainter at 0%, punchy at 100%)
    local function glowTrans() return 0.9 - 0.42 * math.clamp(gradStrength, 0, 1) end

    -- ── Tween helper ──
    local function tw(obj, props, t, style, dir)
        local i = TweenInfo.new(t or 0.2, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out)
        local tween = TweenService:Create(obj, i, props)
        tween:Play()
        return tween
    end

    -- ── Factory ──
    local function new(cls, props, parent)
        local o = Instance.new(cls)
        for k, v in pairs(props) do o[k] = v end
        -- Cache natural transparency at CREATION so open/close anims always
        -- restore the right value (even for elements built lazily later).
        if cls == "Frame" or cls == "ScrollingFrame" then
            o:SetAttribute("_obt", o.BackgroundTransparency)
        elseif cls == "UIStroke" then
            o:SetAttribute("_ot", o.Transparency)
        end
        if parent then o.Parent = parent end
        return o
    end
    local function corner(p, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, p) end
    local function stroke(p, col, th)
        return new("UIStroke", {Color = col or C.border, Thickness = th or 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, p)
    end
    local decorGradients = {}
    local function gradient(p, c1, c2, rotation, decorative)
        local g = Instance.new("UIGradient")
        g.Color = ColorSequence.new(c1, c2)
        g.Rotation = rotation or 90
        g.Parent = p
        if decorative then table.insert(decorGradients, g) end
        return g
    end
    local function lbl(props, parent)
        local o = new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
            TextWrapped = true,
        })
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end

    -- ── Themed-element registry (for live accent swap) ──
    local themed = {}  -- { obj, role }
    local function reg(obj, role) table.insert(themed, {obj = obj, role = role}) return obj end

    -- ── State ──
    local petType = "FR"
    local currentTab = "Custom"
    local rarityRefs = {}
    local tabRefs = {}
    local refreshSelections  -- forward decl

    -- ═══════════════════════════════════════════
    --  ROOT
    -- ═══════════════════════════════════════════
    local ScreenGui = new("ScreenGui", {
        Name = "PetSpawnerGUI",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
    }, PlayerGui)

    local Backdrop = new("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 0,
    }, ScreenGui)

    local WIN_W, WIN_H = 400, 400
    local Window = new("Frame", {
        Name = "Window",
        Size = UDim2.new(0, WIN_W, 0, WIN_H),
        Position = UDim2.new(0.5, -WIN_W/2, 0.5, -WIN_H/2),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, ZIndex = 2,
        ClipsDescendants = true,
    }, ScreenGui)
    corner(Window, 14)
    stroke(Window, Color3.fromRGB(58, 58, 90), 1)
    local winBgGrad = gradient(Window, accentBg(), accentBgBottom(), 145, true)
    reg(winBgGrad, "gradBg")

    -- Soft accent glow halo at the top (premium gradient feel)
    local topGlow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 150), Position = UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = ACCENT.base, BackgroundTransparency = glowTrans(),
        BorderSizePixel = 0, ZIndex = 1,
    }, Window)
    corner(topGlow, 14)
    local glowGrad = Instance.new("UIGradient")
    glowGrad.Color = ColorSequence.new(ACCENT.base, ACCENT.base)
    glowGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.45),
        NumberSequenceKeypoint.new(1, 1),
    })
    glowGrad.Rotation = 90
    glowGrad.Parent = topGlow
    reg(topGlow, "bg")
    reg(glowGrad, "gradGlow")

    local ReopenBtn  -- forward
    local showActivePanel  -- forward: instantly makes the active tab's content visible

    -- Walk up to Window: skip fade if this element OR any ancestor is tagged _skipFade.
    -- (Lets us exclude the hundreds of pet rows, which live in a closed/clipped dropdown.)
    local function shouldSkipFade(obj)
        local a = obj
        while a and a ~= Window do
            if a:GetAttribute("_skipFade") then return true end
            a = a.Parent
        end
        return false
    end

    -- ── Open / Close animations ──
    local function playOpenAnim()
        Window.Visible = true
        Window.BackgroundTransparency = 1
        Window.Size = UDim2.new(0, WIN_W - 30, 0, WIN_H - 30)
        Window.Position = UDim2.new(0.5, -(WIN_W-30)/2, 0.5, -(WIN_H-30)/2)
        for _, obj in ipairs(Window:GetDescendants()) do
            if not shouldSkipFade(obj) then
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then obj.TextTransparency = 1 end
            if obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                if obj:GetAttribute("_obt") == nil then obj:SetAttribute("_obt", obj.BackgroundTransparency) end
                obj.BackgroundTransparency = 1
            end
            if obj:IsA("UIStroke") then
                if obj:GetAttribute("_ot") == nil then obj:SetAttribute("_ot", obj.Transparency) end
                obj.Transparency = 1
            end
            end
        end
        -- Make the ACTIVE tab's content visible immediately (no timing dependence).
        -- The window itself still scales/fades in; chrome fades via the loop below.
        if showActivePanel then showActivePanel() end
        tw(Window, {BackgroundTransparency = 0,
            Size = UDim2.new(0, WIN_W, 0, WIN_H),
            Position = UDim2.new(0.5, -WIN_W/2, 0.5, -WIN_H/2)},
            0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        task.delay(0.08, function()
            for _, obj in ipairs(Window:GetDescendants()) do
                if not shouldSkipFade(obj) then
                if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                    tw(obj, {TextTransparency = 0}, 0.28)
                elseif obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                    tw(obj, {BackgroundTransparency = obj:GetAttribute("_obt") or 0}, 0.28)
                elseif obj:IsA("UIStroke") then
                    tw(obj, {Transparency = obj:GetAttribute("_ot") or 0}, 0.28)
                end
                end
            end
        end)
    end

    local function playCloseAnim()
        local FADE = 0.26
        local ES = Enum.EasingStyle.Quad
        local ED = Enum.EasingDirection.Out
        -- Shrink (visual only — does not affect fade sync)
        tw(Window, {
            Size = UDim2.new(0, WIN_W - 30, 0, WIN_H - 30),
            Position = UDim2.new(0.5, -(WIN_W-30)/2, 0.5, -(WIN_H-30)/2),
        }, FADE, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
        -- Fade EVERYTHING on one identical clock so nothing leads or lags
        tw(Backdrop, {BackgroundTransparency = 1}, FADE, ES, ED)
        tw(Window, {BackgroundTransparency = 1}, FADE, ES, ED)
        for _, obj in ipairs(Window:GetDescendants()) do
            if not shouldSkipFade(obj) then
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                tw(obj, {TextTransparency = 1}, FADE, ES, ED)
            end
            if (obj:IsA("Frame") or obj:IsA("ScrollingFrame")) and obj.BackgroundTransparency < 1 then
                tw(obj, {BackgroundTransparency = 1}, FADE, ES, ED)
            end
            if obj:IsA("UIStroke") then tw(obj, {Transparency = 1}, FADE, ES, ED) end
            end
        end
        task.delay(FADE + 0.04, function()
            Window.Visible = false
            if ReopenBtn then ReopenBtn.Visible = true end
        end)
    end

    -- ═══════════════════════════════════════════
    --  TITLEBAR
    -- ═══════════════════════════════════════════
    local TitleBar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1,
        BorderSizePixel = 0, ZIndex = 5,
    }, Window)

    -- Drag (mouse + touch)
    local dragging = false
    local dragStart, winStart
    TitleBar.Active = true
    TitleBar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = i.Position; winStart = Window.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - dragStart
            Window.Position = UDim2.new(winStart.X.Scale, winStart.X.Offset + d.X,
                winStart.Y.Scale, winStart.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- Traffic lights
    local function makeDot(color, xOffset, onClick)
        local c = new("Frame", {Size=UDim2.new(0,13,0,13), Position=UDim2.new(0,xOffset,0.5,-6.5),
            BackgroundColor3=color, BorderSizePixel=0, ZIndex=7}, TitleBar)
        corner(c, 7)
        local dotShadow = stroke(c, Color3.fromRGB(0,0,0), 1)
        dotShadow.Transparency = 0.6
        dotShadow:SetAttribute("_ot", 0.6)
        local b = new("TextButton", {Size=UDim2.new(1,0,1,0), BackgroundTransparency=1, Text="", ZIndex=9}, c)
        b.MouseEnter:Connect(function() tw(c, {Size=UDim2.new(0,14,0,14), Position=UDim2.new(0,xOffset-0.5,0.5,-7)}, 0.12) end)
        b.MouseLeave:Connect(function() tw(c, {Size=UDim2.new(0,13,0,13), Position=UDim2.new(0,xOffset,0.5,-6.5)}, 0.12) end)
        if onClick then b.MouseButton1Click:Connect(function() playClick() onClick() end) end
    end
    makeDot(C.dotR, 16, function() playCloseAnim() end)
    makeDot(C.dotY, 35, function() playCloseAnim() end)
    makeDot(C.dotG, 54, nil)

    lbl({Size=UDim2.new(1,0,1,0), Text="pet  \u{B7}  spawner", TextColor3=C.muted,
        TextSize=12, Font=Enum.Font.GothamMedium,
        TextXAlignment=Enum.TextXAlignment.Center, ZIndex=6}, TitleBar)

    -- ═══════════════════════════════════════════
    --  TAB BAR (segmented control)
    -- ═══════════════════════════════════════════
    local TabBarHolder = new("Frame", {
        Size = UDim2.new(1, -24, 0, 36),
        Position = UDim2.new(0, 12, 0, 52),
        BackgroundColor3 = C.panel, BorderSizePixel = 0,
    }, Window)
    corner(TabBarHolder, 10)
    stroke(TabBarHolder, C.border, 1)
    gradient(TabBarHolder, C.cardGradA, C.cardGradB, 90, true)

    -- Sliding highlight pill
    local TABS = {"Custom", "Misc", "Settings"}
    local tabCount = #TABS
    local highlight = new("Frame", {
        Size = UDim2.new(1/tabCount, -6, 1, -6),
        Position = UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = ACCENT.dim, BorderSizePixel = 0, ZIndex = 2,
    }, TabBarHolder)
    corner(highlight, 8)
    reg(highlight, "bgDim")
    local hlStroke = stroke(highlight, ACCENT.base, 1)
    reg(hlStroke, "stroke")

    local ContentArea  -- forward
    local panels = {}

    local function restorePanelOpacity(p)
        for _, obj in ipairs(p:GetDescendants()) do
            if not shouldSkipFade(obj) then
                if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                    obj.TextTransparency = 0
                elseif obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                    obj.BackgroundTransparency = obj:GetAttribute("_obt") or 0
                elseif obj:IsA("UIStroke") then
                    obj.Transparency = obj:GetAttribute("_ot") or 0
                end
            end
        end
    end

    -- Assign the forward-declared helper: instantly reveal the current tab's content.
    -- Mirrors switchTab's visibility/position handling (panels are hidden during init).
    showActivePanel = function()
        local cur = panels[currentTab]
        if not cur then return end
        for pname, p in pairs(panels) do
            p.Visible = (pname == currentTab)
        end
        cur.Position = UDim2.new(0, 0, 0, 0)
        restorePanelOpacity(cur)
    end

    local function switchTab(name, index)
        currentTab = name
        -- Move highlight
        tw(highlight, {Position = UDim2.new((index-1)/tabCount, 3, 0, 3)}, 0.28, Enum.EasingStyle.Back)
        -- Tab label colors
        for tname, ref in pairs(tabRefs) do
            tw(ref.text, {TextColor3 = (tname == name) and ACCENT.light or C.muted}, 0.18)
        end
        -- Show/hide panels with slide
        for pname, p in pairs(panels) do
            if pname == name then
                restorePanelOpacity(p)
                p.Visible = true
                p.Position = UDim2.new(0, 14, 0, 0)
                tw(p, {Position = UDim2.new(0, 0, 0, 0)}, 0.3, Enum.EasingStyle.Quint)
            else
                p.Visible = false
            end
        end
    end

    for i, tname in ipairs(TABS) do
        local txt = lbl({
            Size = UDim2.new(1/tabCount, 0, 1, 0),
            Position = UDim2.new((i-1)/tabCount, 0, 0, 0),
            Text = tname,
            TextColor3 = (tname == "Custom") and ACCENT.light or C.muted,
            TextSize = 12, Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3,
        }, TabBarHolder)
        tabRefs[tname] = {text = txt}
        local b = new("TextButton", {
            Size = UDim2.new(1/tabCount, 0, 1, 0),
            Position = UDim2.new((i-1)/tabCount, 0, 0, 0),
            BackgroundTransparency = 1, Text = "", ZIndex = 4,
        }, TabBarHolder)
        b.MouseButton1Click:Connect(function() playClick() switchTab(tname, i) end)
    end

    -- ═══════════════════════════════════════════
    --  CONTENT AREA
    -- ═══════════════════════════════════════════
    ContentArea = new("Frame", {
        Size = UDim2.new(1, 0, 1, -100),
        Position = UDim2.new(0, 0, 0, 96),
        BackgroundTransparency = 1, ClipsDescendants = true,
    }, Window)

    local function makePanel(name)
        local p = new("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1, BorderSizePixel = 0,
            Visible = name == "Custom",
        }, ContentArea)
        p:SetAttribute("_isPanel", true)
        new("UIListLayout", {FillDirection = Enum.FillDirection.Vertical,
            Padding = UDim.new(0, 11), SortOrder = Enum.SortOrder.LayoutOrder}, p)
        new("UIPadding", {PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 18),
            PaddingRight = UDim.new(0, 18), PaddingBottom = UDim.new(0, 16)}, p)
        panels[name] = p
        return p
    end

    local function sectionLabel(text, parent, order)
        local f = new("Frame", {Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1, LayoutOrder = order}, parent)
        lbl({Size = UDim2.new(1, 0, 1, 0), Text = text, TextColor3 = C.muted,
            TextSize = 10, Font = Enum.Font.GothamBold}, f)
        return f
    end

    -- ═══════════════════════════════════════════
    --  MAIN TAB
    -- ═══════════════════════════════════════════
    local MainP = makePanel("Main")

    sectionLabel("PET NAME", MainP, 1)

    -- Input card
    local InputCard = new("Frame", {
        Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = C.card,
        BorderSizePixel = 0, LayoutOrder = 2,
    }, MainP)
    corner(InputCard, 10)
    local inpStroke = stroke(InputCard, C.border, 1)
    gradient(InputCard, C.cardGradA, C.cardGradB, 90, true)
    lbl({Size = UDim2.new(0, 22, 1, 0), Position = UDim2.new(0, 14, 0, 0),
        Text = "\u{1F50D}", TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center}, InputCard)
    local PetInput = new("TextBox", {
        Size = UDim2.new(1, -52, 1, -12), Position = UDim2.new(0, 42, 0, 6),
        BackgroundTransparency = 1, PlaceholderText = "e.g. Shadow Dragon, Frost Fury\u{2026}",
        PlaceholderColor3 = C.dim, Text = "", TextColor3 = C.text,
        Font = Enum.Font.GothamMedium, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
    }, InputCard)
    PetInput.Focused:Connect(function() tw(inpStroke, {Color = ACCENT.base}, 0.15) end)
    PetInput.FocusLost:Connect(function() tw(inpStroke, {Color = C.border}, 0.15) end)

    sectionLabel("RARITY", MainP, 3)

    -- Rarity segmented row
    local rarityRow = new("Frame", {Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1, LayoutOrder = 4}, MainP)

    local RARITIES = {
        {key = "FR",  title = "FR",  sub = "Fly Ride",   icon = "\u{2B50}"},
        {key = "NFR", title = "NFR", sub = "Neon",       icon = "\u{1F31F}"},
        {key = "MFR", title = "MFR", sub = "Mega Neon",  icon = "\u{2728}"},
    }

    local function selectRarity(key)
        petType = key
        for _, ref in pairs(rarityRefs) do
            local active = ref.key == key
            tw(ref.card, {BackgroundColor3 = active and ACCENT.dim or C.card}, 0.2)
            tw(ref.stroke, {Color = active and ACCENT.base or C.border, Thickness = active and 1.5 or 1}, 0.2)
            tw(ref.title, {TextColor3 = active and ACCENT.light or C.text}, 0.2)
            tw(ref.icon, {TextColor3 = active and ACCENT.light or C.muted}, 0.2)
        end
    end

    for i, r in ipairs(RARITIES) do
        local x = (i - 1) / 3
        local card = new("Frame", {
            Size = UDim2.new(1/3, -6, 1, 0),
            Position = UDim2.new(x, (i == 1) and 0 or 4, 0, 0),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, rarityRow)
        corner(card, 10)
        local cStroke = stroke(card, C.border, 1)
        gradient(card, C.cardGradA, C.cardGradB, 90, true)

        local iconLbl = lbl({Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 8),
            Text = r.icon, TextSize = 16, TextColor3 = C.muted, Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Center}, card)
        local titleLbl = lbl({Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 0, 28),
            Text = r.title, TextSize = 12, TextColor3 = C.text, Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Center}, card)
        local subLbl = lbl({Size = UDim2.new(1, 0, 0, 11), Position = UDim2.new(0, 0, 1, -16),
            Text = r.sub, TextSize = 8, TextColor3 = C.dim,
            TextXAlignment = Enum.TextXAlignment.Center}, card)

        rarityRefs[r.key] = {card = card, stroke = cStroke, title = titleLbl, icon = iconLbl, key = r.key}

        local b = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 3}, card)
        b.MouseButton1Click:Connect(function() playClick() selectRarity(r.key) end)
        card.MouseEnter:Connect(function()
            if petType ~= r.key then tw(card, {BackgroundColor3 = C.cardHov}, 0.14) tw(cStroke, {Color = ACCENT.base:Lerp(C.border, 0.4)}, 0.14) end
        end)
        card.MouseLeave:Connect(function()
            if petType ~= r.key then tw(card, {BackgroundColor3 = C.card}, 0.14) tw(cStroke, {Color = C.border}, 0.14) end
        end)
    end

    -- Global toast (lives on the Window so it shows on ANY tab)
    local feedbackHolder = new("Frame", {Size = UDim2.new(1, 0, 0, 8), BackgroundTransparency = 1, LayoutOrder = 5}, MainP)
    local Feedback = new("Frame", {
        Size = UDim2.new(0, 0, 0, 30), Position = UDim2.new(0.5, 0, 1, -14),
        AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = C.card,
        BorderSizePixel = 0, Visible = false, ZIndex = 60,
    }, Window)
    corner(Feedback, 13)
    Feedback:SetAttribute("_skipFade", true)
    local fbStroke = stroke(Feedback, C.border, 1)
    local fbDot = new("Frame", {Size = UDim2.new(0, 7, 0, 7), Position = UDim2.new(0, 12, 0.5, -3.5),
        BackgroundColor3 = C.green, BorderSizePixel = 0, ZIndex = 61}, Feedback)
    corner(fbDot, 4)
    local fbLbl = lbl({Size = UDim2.new(1, -30, 1, 0), Position = UDim2.new(0, 26, 0, 0),
        Text = "", TextColor3 = C.text, TextSize = 11, Font = Enum.Font.GothamMedium, ZIndex = 61}, Feedback)

    local fbToken = 0
    local function showFeedback(text, color)
        fbToken = fbToken + 1
        local myToken = fbToken
        local col = color or C.green
        fbLbl.Text = text
        fbDot.BackgroundColor3 = col
        fbStroke.Color = col

        -- Size to fit instantly (no width animation = no text clipping)
        local w = math.clamp(#text * 6 + 50, 90, 360)
        Feedback.Size = UDim2.new(0, w, 0, 30)
        Feedback.Visible = true

        -- Start hidden + nudged down, then fade & slide up into place together
        Feedback.Position = UDim2.new(0.5, 0, 1, -6)
        Feedback.BackgroundTransparency = 1
        fbStroke.Transparency = 1
        fbDot.BackgroundTransparency = 1
        fbLbl.TextTransparency = 1
        tw(Feedback, {Position = UDim2.new(0.5, 0, 1, -14), BackgroundTransparency = 0}, 0.22, Enum.EasingStyle.Quad)
        tw(fbStroke, {Transparency = 0}, 0.22, Enum.EasingStyle.Quad)
        tw(fbDot, {BackgroundTransparency = 0}, 0.22, Enum.EasingStyle.Quad)
        tw(fbLbl, {TextTransparency = 0}, 0.22, Enum.EasingStyle.Quad)

        -- Close after a delay — but only if no newer toast replaced this one
        task.delay(2.4, function()
            if myToken ~= fbToken then return end
            tw(Feedback, {Position = UDim2.new(0.5, 0, 1, -22), BackgroundTransparency = 1}, 0.25, Enum.EasingStyle.Quad)
            tw(fbStroke, {Transparency = 1}, 0.25, Enum.EasingStyle.Quad)
            tw(fbDot, {BackgroundTransparency = 1}, 0.25, Enum.EasingStyle.Quad)
            tw(fbLbl, {TextTransparency = 1}, 0.25, Enum.EasingStyle.Quad)
            task.delay(0.27, function()
                if myToken ~= fbToken then return end
                Feedback.Visible = false
            end)
        end)
    end

    -- Spawn button
    local spawnHolder = new("Frame", {Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1, LayoutOrder = 6}, MainP)
    local SpawnBtn = new("TextButton", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = ACCENT.base,
        BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, spawnHolder)
    corner(SpawnBtn, 11)
    reg(SpawnBtn, "bg")
    local spawnGrad = gradient(SpawnBtn, ACCENT.light, ACCENT.base, 90)
    reg(spawnGrad, "gradAccent")
    local spawnStroke = stroke(SpawnBtn, ACCENT.light, 1)
    reg(spawnStroke, "stroke")
    local spawnLbl = lbl({Size = UDim2.new(1, 0, 1, 0), Text = "\u{1F43E}  Spawn Pet",
        TextColor3 = C.white, TextSize = 14, Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center}, SpawnBtn)
    SpawnBtn.MouseEnter:Connect(function() tw(SpawnBtn, {BackgroundColor3 = ACCENT.light}, 0.14) end)
    SpawnBtn.MouseLeave:Connect(function() tw(SpawnBtn, {BackgroundColor3 = ACCENT.base}, 0.14) end)
    SpawnBtn.MouseButton1Down:Connect(function() tw(SpawnBtn, {Size = UDim2.new(1, -4, 1, -2)}, 0.08) end)
    SpawnBtn.MouseButton1Up:Connect(function() tw(SpawnBtn, {Size = UDim2.new(1, 0, 1, 0)}, 0.15, Enum.EasingStyle.Back) end)
    SpawnBtn.MouseButton1Click:Connect(function()
        playClick()
        local nameText = PetInput.Text
        if nameText == "" then showFeedback("Enter a pet name first", C.amber) return end
        local petId = GetPetByName(nameText)
        if petId then
            if petType == 'FR' then
                createPet(petId, {pet_trick_level=0, rideable=true, flyable=true,
                    friendship_level=0, age=1, ailments_completed=0, rp_name=""})
            elseif petType == 'MFR' then
                createPet(petId, {pet_trick_level=0, mega_neon=true, rideable=true, flyable=true,
                    friendship_level=0, age=1, ailments_completed=0, rp_name=""})
            elseif petType == 'NFR' then
                createPet(petId, {pet_trick_level=0, neon=true, rideable=true, flyable=true,
                    friendship_level=0, age=1, ailments_completed=0, rp_name=""})
            end
            showFeedback("\u{2713}  Spawned " .. nameText .. "  (" .. petType .. ")", C.green)
        else
            showFeedback("Pet not found \u{2014} check spelling", C.red)
        end
    end)

    -- ═══════════════════════════════════════════
    --  "COMING SOON" PANEL BUILDER (reused by Custom + Misc)
    -- ═══════════════════════════════════════════
    local function buildComingSoon(panel, titleText, subText)
        local wipHolder = new("Frame", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, LayoutOrder = 1}, panel)

        local wipCard = new("Frame", {
            Size = UDim2.new(1, 0, 0, 170),
            Position = UDim2.new(0, 0, 0.5, -95),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, wipHolder)
        corner(wipCard, 14)
        stroke(wipCard, C.border, 1)
        gradient(wipCard, C.cardGradA, C.cardGradB, 135, true)

        -- Animated gear icon
        local gearLbl = lbl({Size = UDim2.new(0, 60, 0, 60), Position = UDim2.new(0.5, -30, 0, 26),
            Text = "\u{2699}\u{FE0F}", TextSize = 40, TextXAlignment = Enum.TextXAlignment.Center}, wipCard)
        task.spawn(function()
            while ScreenGui.Parent do
                tw(gearLbl, {Rotation = 12}, 1.2, Enum.EasingStyle.Sine)
                task.wait(1.2)
                tw(gearLbl, {Rotation = -12}, 1.2, Enum.EasingStyle.Sine)
                task.wait(1.2)
            end
        end)

        lbl({Size = UDim2.new(1, -24, 0, 22), Position = UDim2.new(0, 12, 0, 92),
            Text = titleText or "Soon", TextColor3 = C.text, TextSize = 18, Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Center}, wipCard)
        lbl({Size = UDim2.new(1, -24, 0, 16), Position = UDim2.new(0, 12, 0, 116),
            Text = subText or "Work in progress", TextColor3 = C.muted, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Center}, wipCard)

        -- Animated progress dots
        local dotsHolder = new("Frame", {Size = UDim2.new(0, 44, 0, 8), Position = UDim2.new(0.5, -22, 0, 142),
            BackgroundTransparency = 1}, wipCard)
        local wipDots = {}
        for i = 1, 3 do
            local d = new("Frame", {Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, (i-1)*18, 0, 0),
                BackgroundColor3 = ACCENT.base, BorderSizePixel = 0}, dotsHolder)
            corner(d, 4)
            reg(d, "bg")
            wipDots[i] = d
        end
        task.spawn(function()
            while ScreenGui.Parent do
                for i = 1, 3 do
                    tw(wipDots[i], {BackgroundTransparency = 0}, 0.2)
                    tw(wipDots[i], {Size = UDim2.new(0, 9, 0, 9), Position = UDim2.new(0, (i-1)*18-0.5, 0, -0.5)}, 0.2)
                    task.wait(0.18)
                    tw(wipDots[i], {BackgroundTransparency = 0.6}, 0.3)
                    tw(wipDots[i], {Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, (i-1)*18, 0, 0)}, 0.3)
                end
                task.wait(0.5)
            end
        end)
    end

    -- ═══════════════════════════════════════════
    --  CUSTOM TAB — searchable pet browser (auto-built from game data)
    -- ═══════════════════════════════════════════
    local CustomP = makePanel("Custom")
    CustomP.Visible = false

    -- single root frame (manual layout inside the panel's list slot)
    local customRoot = new("Frame", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, LayoutOrder = 1}, CustomP)

    -- Compact rarity selector (Custom uses its own choice)
    local customRarity = "FR"
    local customRarityRefs = {}
    local CR_TYPES = {
        {key = "FR",  icon = "\u{2B50}"},
        {key = "NFR", icon = "\u{1F31F}"},
        {key = "MFR", icon = "\u{2728}"},
    }
    local function selectCustomRarity(key)
        customRarity = key
        for _, ref in pairs(customRarityRefs) do
            local active = ref.key == key
            tw(ref.card, {BackgroundColor3 = active and ACCENT.dim or C.card}, 0.18)
            tw(ref.stroke, {Color = active and ACCENT.base or C.border, Thickness = active and 1.5 or 1}, 0.18)
            tw(ref.lbl, {TextColor3 = active and ACCENT.light or C.text}, 0.18)
        end
    end
    for i, t in ipairs(CR_TYPES) do
        local x = (i - 1) / 3
        local card = new("Frame", {
            Size = UDim2.new(1/3, -5, 0, 34), Position = UDim2.new(x, (i == 1) and 0 or 4, 0, 0),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, customRoot)
        corner(card, 9)
        local cStroke = stroke(card, C.border, 1)
        gradient(card, C.cardGradA, C.cardGradB, 90, true)
        local tlbl = lbl({Size = UDim2.new(1, 0, 1, 0), Text = t.icon .. "  " .. t.key,
            TextColor3 = C.text, TextSize = 11, Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Center}, card)
        customRarityRefs[t.key] = {card = card, stroke = cStroke, lbl = tlbl, key = t.key}
        local b = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 3}, card)
        b.MouseButton1Click:Connect(function() playClick() selectCustomRarity(t.key) end)
    end

    -- Dropdown header (toggles the browser open/closed)
    local ddOpen = false
    local ddHeader = new("Frame", {
        Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0, 42),
        BackgroundColor3 = C.card, BorderSizePixel = 0,
    }, customRoot)
    corner(ddHeader, 10)
    local ddStroke = stroke(ddHeader, C.border, 1)
    gradient(ddHeader, C.cardGradA, C.cardGradB, 90, true)
    lbl({Size = UDim2.new(0, 22, 1, 0), Position = UDim2.new(0, 12, 0, 0),
        Text = "\u{1F43E}", TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center}, ddHeader)
    local ddTitle = lbl({Size = UDim2.new(1, -70, 1, 0), Position = UDim2.new(0, 38, 0, 0),
        Text = "Browse all pets", TextColor3 = C.text, TextSize = 13, Font = Enum.Font.GothamMedium}, ddHeader)
    local ddArrow = lbl({Size = UDim2.new(0, 24, 1, 0), Position = UDim2.new(1, -30, 0, 0),
        Text = "\u{25BC}", TextColor3 = C.muted, TextSize = 11, Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center}, ddHeader)

    -- Dropdown body (search + scrolling list) — clipped, expands when open
    local ddBody = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), Position = UDim2.new(0, 0, 0, 90),
        BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true,
    }, customRoot)

    -- Search box
    local searchCard = new("Frame", {Size = UDim2.new(1, -20, 0, 34), Position = UDim2.new(0, 10, 0, 6),
        BackgroundColor3 = C.inputBg, BorderSizePixel = 0}, ddBody)
    corner(searchCard, 8)
    local searchStroke = stroke(searchCard, C.border, 1)
    lbl({Size = UDim2.new(0, 20, 1, 0), Position = UDim2.new(0, 10, 0, 0),
        Text = "\u{1F50D}", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center}, searchCard)
    local searchBox = new("TextBox", {
        Size = UDim2.new(1, -42, 1, -8), Position = UDim2.new(0, 34, 0, 4),
        BackgroundTransparency = 1, PlaceholderText = "Search pets\u{2026}",
        PlaceholderColor3 = C.dim, Text = "", TextColor3 = C.text,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
    }, searchCard)
    searchBox.Focused:Connect(function() tw(searchStroke, {Color = ACCENT.base}, 0.15) end)
    searchBox.FocusLost:Connect(function() tw(searchStroke, {Color = C.border}, 0.15) end)

    -- Scrolling list of pet buttons
    local petScroll = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -48), Position = UDim2.new(0, 0, 0, 48),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = ACCENT.base,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, ddBody)
    petScroll:SetAttribute("_skipFade", true)
    reg(petScroll, "scroll")
    new("UIListLayout", {FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 5),
        SortOrder = Enum.SortOrder.LayoutOrder}, petScroll)
    new("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 4)}, petScroll)

    -- "Loading" placeholder shown until the list builds
    local loadingLbl = lbl({Size = UDim2.new(1, 0, 0, 40), Text = "Loading pets\u{2026}",
        TextColor3 = C.muted, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center,
        LayoutOrder = 0}, petScroll)

    -- Spawn from Custom (uses customRarity)
    local function customProps()
        if customRarity == "MFR" then
            return {pet_trick_level=0, mega_neon=true, rideable=true, flyable=true, friendship_level=0, age=1, ailments_completed=0, rp_name=""}
        elseif customRarity == "NFR" then
            return {pet_trick_level=0, neon=true, rideable=true, flyable=true, friendship_level=0, age=1, ailments_completed=0, rp_name=""}
        end
        return {pet_trick_level=0, rideable=true, flyable=true, friendship_level=0, age=1, ailments_completed=0, rp_name=""}
    end

    -- Lazy-build the full pet list from InventoryDB on first open
    local petListBuilt = false
    local petEntries = {}  -- { btn, nameLower }
    local function buildPetList(onProgress)
        if petListBuilt then return end
        petListBuilt = true
        -- collect + sort alphabetically
        local arr = {}
        for _, v in pairs(InventoryDB.pets) do
            if type(v) == "table" and v.name and v.id then
                arr[#arr + 1] = v
            end
        end
        table.sort(arr, function(a, b) return a.name:lower() < b.name:lower() end)

        local total = #arr
        ddTitle.Text = "Browse all pets (" .. total .. ")"

        for idx, v in ipairs(arr) do
            local petName = tostring(v.name)
            local petId = v.id
            local row = new("Frame", {Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.card,
                BorderSizePixel = 0, LayoutOrder = idx}, petScroll)
            corner(row, 8)
            local rowStroke = stroke(row, C.border, 1)
            lbl({Size = UDim2.new(1, -54, 1, 0), Position = UDim2.new(0, 12, 0, 0),
                Text = petName, TextColor3 = C.text, TextSize = 12, Font = Enum.Font.GothamMedium}, row)
            local spawnPill = new("Frame", {Size = UDim2.new(0, 42, 0, 20), Position = UDim2.new(1, -48, 0.5, -10),
                BackgroundColor3 = C.inputBg, BorderSizePixel = 0}, row)
            corner(spawnPill, 6)
            local spawnPillStroke = stroke(spawnPill, C.border, 1)
            local spawnPillLbl = lbl({Size = UDim2.new(1, 0, 1, 0), Text = "spawn", TextColor3 = C.muted,
                TextSize = 9, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Center}, spawnPill)

            local b = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 3}, row)
            b.MouseEnter:Connect(function()
                tw(row, {BackgroundColor3 = C.cardHov}, 0.12) tw(rowStroke, {Color = ACCENT.base:Lerp(C.border, 0.4)}, 0.12)
                tw(spawnPillStroke, {Color = ACCENT.base}, 0.12) tw(spawnPillLbl, {TextColor3 = ACCENT.light}, 0.12)
            end)
            b.MouseLeave:Connect(function()
                tw(row, {BackgroundColor3 = C.card}, 0.12) tw(rowStroke, {Color = C.border}, 0.12)
                tw(spawnPillStroke, {Color = C.border}, 0.12) tw(spawnPillLbl, {TextColor3 = C.muted}, 0.12)
            end)
            b.MouseButton1Click:Connect(function()
                playClick()
                createPet(petId, customProps())
                showFeedback("\u{2713}  Spawned " .. petName .. "  (" .. customRarity .. ")", C.green)
                spawnPill.BackgroundColor3 = ACCENT.base
                spawnPillLbl.TextColor3 = C.white
                task.delay(0.25, function()
                    tw(spawnPill, {BackgroundColor3 = C.inputBg}, 0.25)
                    tw(spawnPillLbl, {TextColor3 = C.muted}, 0.25)
                end)
            end)

            petEntries[#petEntries + 1] = {btn = row, nameLower = petName:lower()}

            if onProgress then onProgress(idx, total) end
            -- yield periodically so building the list doesn't freeze a frame
            if idx % 40 == 0 then task.wait() end
        end

        if loadingLbl then loadingLbl:Destroy() loadingLbl = nil end
    end

    -- Search filter
    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        local q = searchBox.Text:lower()
        for _, e in ipairs(petEntries) do
            e.btn.Visible = (q == "" or e.nameLower:find(q, 1, true) ~= nil)
        end
    end)

    -- Dropdown open/close
    local DD_OPEN_H = 196   -- body height when open
    local function setDropdown(open)
        ddOpen = open
        if open then buildPetList() end
        tw(ddArrow, {Rotation = open and 180 or 0}, 0.25, Enum.EasingStyle.Quad)
        tw(ddStroke, {Color = open and ACCENT.base or C.border}, 0.2)
        tw(ddTitle, {TextColor3 = open and ACCENT.light or C.text}, 0.2)
        tw(ddBody, {Size = UDim2.new(1, 0, 0, open and DD_OPEN_H or 0)}, 0.3, Enum.EasingStyle.Quint)
    end
    local ddBtn = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 3}, ddHeader)
    ddBtn.MouseButton1Click:Connect(function() playClick() setDropdown(not ddOpen) end)
    ddHeader.MouseEnter:Connect(function() if not ddOpen then tw(ddHeader, {BackgroundColor3 = C.cardHov}, 0.12) end end)
    ddHeader.MouseLeave:Connect(function() if not ddOpen then tw(ddHeader, {BackgroundColor3 = C.card}, 0.12) end end)

    -- default custom rarity highlight
    task.delay(0.05, function()
        local ref = customRarityRefs["FR"]
        if ref then
            ref.card.BackgroundColor3 = ACCENT.dim
            ref.stroke.Color = ACCENT.base
            ref.stroke.Thickness = 1.5
            ref.lbl.TextColor3 = ACCENT.light
        end
    end)

    -- ═══════════════════════════════════════════
    --  MISC TAB (work in progress)
    -- ═══════════════════════════════════════════
    local MiscP = makePanel("Misc")
    MiscP.Visible = false
    buildComingSoon(MiscP, "Soon", "Misc features coming soon")

    -- ═══════════════════════════════════════════
    --  SETTINGS TAB
    -- ═══════════════════════════════════════════
    local SetP = makePanel("Settings")
    SetP.Visible = false

    sectionLabel("ACCENT COLOR", SetP, 1)

    -- Swatch grid (two rows)
    local swatchRow = new("Frame", {Size = UDim2.new(1, 0, 0, 84), BackgroundTransparency = 1, LayoutOrder = 2}, SetP)
    local swatchRefs = {}
    local swPerRow = 6
    local swRowH = 42

    refreshSelections = function()
        -- recolor active rarity + active tab + highlight live
        for _, ref in pairs(rarityRefs) do
            if ref.key == petType then
                tw(ref.card, {BackgroundColor3 = ACCENT.dim}, 0.2)
                tw(ref.stroke, {Color = ACCENT.base}, 0.2)
                tw(ref.title, {TextColor3 = ACCENT.light}, 0.2)
                tw(ref.icon, {TextColor3 = ACCENT.light}, 0.2)
            end
        end
        -- Custom tab uses its own rarity selector
        for _, ref in pairs(customRarityRefs) do
            if ref.key == customRarity then
                tw(ref.card, {BackgroundColor3 = ACCENT.dim}, 0.2)
                tw(ref.stroke, {Color = ACCENT.base}, 0.2)
                tw(ref.lbl, {TextColor3 = ACCENT.light}, 0.2)
            end
        end
        for tname, ref in pairs(tabRefs) do
            if tname == currentTab then tw(ref.text, {TextColor3 = ACCENT.light}, 0.2) end
        end
        -- open dropdown keeps its accent border + title
        if ddOpen then
            tw(ddStroke, {Color = ACCENT.base}, 0.2)
            tw(ddTitle, {TextColor3 = ACCENT.light}, 0.2)
        end
    end

    local function applyAccent(idx)
        local a = ACCENTS[idx]
        ACCENT.base = a.base; ACCENT.dim = a.dim; ACCENT.light = a.light
        -- Update all registered themed elements
        for _, t in ipairs(themed) do
            if t.role == "bg" then tw(t.obj, {BackgroundColor3 = ACCENT.base}, 0.25)
            elseif t.role == "bgDim" then tw(t.obj, {BackgroundColor3 = ACCENT.dim}, 0.25)
            elseif t.role == "text" then tw(t.obj, {TextColor3 = ACCENT.light}, 0.25)
            elseif t.role == "stroke" then tw(t.obj, {Color = ACCENT.base}, 0.25)
            elseif t.role == "gradAccent" then t.obj.Color = ColorSequence.new(ACCENT.light, ACCENT.base)
            elseif t.role == "gradGlow" then t.obj.Color = ColorSequence.new(ACCENT.base, ACCENT.base)
            elseif t.role == "gradBg" then t.obj.Color = ColorSequence.new(accentBg(), accentBgBottom())
            elseif t.role == "scroll" then t.obj.ScrollBarImageColor3 = ACCENT.base
            end
        end
        -- Update swatch selection rings (and cache _ot so a tab-switch keeps it)
        for i, ref in pairs(swatchRefs) do
            local tr = (i == idx) and 0 or 1
            tw(ref.ring, {Transparency = tr}, 0.2)
            ref.ring:SetAttribute("_ot", tr)
        end
        refreshSelections()
    end

    for i, a in ipairs(ACCENTS) do
        local col = (i - 1) % swPerRow
        local row = math.floor((i - 1) / swPerRow)
        local holder = new("Frame", {
            Size = UDim2.new(1/swPerRow, -6, 0, 42),
            Position = UDim2.new(col/swPerRow, (col == 0) and 0 or 4, 0, row * swRowH),
            BackgroundTransparency = 1,
        }, swatchRow)

        local sw = new("Frame", {
            Size = UDim2.new(0, 32, 0, 32), Position = UDim2.new(0.5, -16, 0, 0),
            BackgroundColor3 = a.base, BorderSizePixel = 0,
        }, holder)
        corner(sw, 16)
        gradient(sw, a.light, a.base, 135)

        -- Selection ring
        local ring = new("UIStroke", {Color = C.white, Thickness = 2,
            Transparency = (i == 1) and 0 or 1}, sw)

        lbl({Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10),
            Text = a.name, TextColor3 = C.muted, TextSize = 8,
            TextXAlignment = Enum.TextXAlignment.Center}, holder)

        swatchRefs[i] = {sw = sw, ring = ring}

        local b = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 3}, holder)
        b.MouseButton1Click:Connect(function() playClick() applyAccent(i) end)
        sw.MouseEnter:Connect(function() tw(sw, {Size = UDim2.new(0, 34, 0, 34), Position = UDim2.new(0.5, -17, 0, -1)}, 0.12) end)
        sw.MouseLeave:Connect(function() tw(sw, {Size = UDim2.new(0, 32, 0, 32), Position = UDim2.new(0.5, -16, 0, 0)}, 0.12) end)
    end

    sectionLabel("APPEARANCE", SetP, 3)

    -- Gradient toggle row
    local gradRow = new("Frame", {Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = C.card,
        BorderSizePixel = 0, LayoutOrder = 4}, SetP)
    corner(gradRow, 10)
    stroke(gradRow, C.border, 1)
    gradient(gradRow, C.cardGradA, C.cardGradB, 90, true)
    lbl({Size = UDim2.new(1, -70, 0, 16), Position = UDim2.new(0, 14, 0, 8),
        Text = "Gradients", TextColor3 = C.text, TextSize = 13, Font = Enum.Font.GothamMedium}, gradRow)
    lbl({Size = UDim2.new(1, -70, 0, 12), Position = UDim2.new(0, 14, 0, 26),
        Text = "Toggle gradient backgrounds", TextColor3 = C.muted, TextSize = 10}, gradRow)

    local gTrack = new("Frame", {Size = UDim2.new(0, 42, 0, 24), Position = UDim2.new(1, -56, 0.5, -12),
        BackgroundColor3 = ACCENT.base, BorderSizePixel = 0}, gradRow)
    corner(gTrack, 12)
    reg(gTrack, "bg")
    stroke(gTrack, Color3.fromRGB(55, 55, 80), 1)
    local gKnob = new("Frame", {Size = UDim2.new(0, 18, 0, 18), Position = UDim2.new(0, 21, 0.5, -9),
        BackgroundColor3 = C.white, BorderSizePixel = 0, ZIndex = 2}, gTrack)
    corner(gKnob, 9)
    local gKnobShadow = stroke(gKnob, Color3.fromRGB(0,0,0), 1)
    gKnobShadow.Transparency = 0.7
    gKnobShadow:SetAttribute("_ot", 0.7)

    local gBtn = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 4}, gradRow)
    gBtn.MouseButton1Click:Connect(function()
        playClick()
        gradientsEnabled = not gradientsEnabled
        for _, g in ipairs(decorGradients) do g.Enabled = gradientsEnabled end
        tw(gTrack, {BackgroundColor3 = gradientsEnabled and ACCENT.base or C.off}, 0.22)
        tw(gKnob, {Position = gradientsEnabled and UDim2.new(0, 21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)},
            0.22, Enum.EasingStyle.Back)
    end)

    -- Gradient strength row
    local rotRow = new("Frame", {Size = UDim2.new(1, 0, 0, 56), BackgroundColor3 = C.card,
        BorderSizePixel = 0, LayoutOrder = 5}, SetP)
    corner(rotRow, 10)
    stroke(rotRow, C.border, 1)
    gradient(rotRow, C.cardGradA, C.cardGradB, 90, true)
    lbl({Size = UDim2.new(0.6, 0, 0, 16), Position = UDim2.new(0, 14, 0, 9),
        Text = "Gradient stronger", TextColor3 = C.text, TextSize = 13, Font = Enum.Font.GothamMedium}, rotRow)
    local rotVal = lbl({Size = UDim2.new(0, 50, 0, 16), Position = UDim2.new(1, -62, 0, 9),
        Text = "50%", TextColor3 = ACCENT.light, TextSize = 13, Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Right}, rotRow)
    reg(rotVal, "text")

    local rTrack = new("Frame", {Size = UDim2.new(1, -28, 0, 5), Position = UDim2.new(0, 14, 0, 38),
        BackgroundColor3 = C.off, BorderSizePixel = 0}, rotRow)
    corner(rTrack, 3)
    local rFill = new("Frame", {Size = UDim2.new(gradStrength, 0, 1, 0), BackgroundColor3 = ACCENT.base, BorderSizePixel = 0}, rTrack)
    corner(rFill, 3)
    reg(rFill, "bg")
    local rThumb = new("Frame", {Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(gradStrength, 0, 0.5, -8),
        BackgroundColor3 = C.white, BorderSizePixel = 0, ZIndex = 3}, rTrack)
    corner(rThumb, 8)
    local rThumbStroke = stroke(rThumb, ACCENT.base, 1.5)
    reg(rThumbStroke, "stroke")

    -- Wide invisible hit area (easy to grab on mobile + desktop)
    local rHit = new("TextButton", {
        Size = UDim2.new(1, -20, 0, 28), Position = UDim2.new(0, 10, 0, 27),
        BackgroundTransparency = 1, Text = "", ZIndex = 5,
    }, rotRow)

    local rSliding = false
    local function updateStrength(px)
        local abs = rTrack.AbsoluteSize.X
        if abs <= 0 then return end
        local rel = px - rTrack.AbsolutePosition.X
        local p = math.clamp(rel / abs, 0, 1)
        gradStrength = p
        rFill.Size = UDim2.new(p, 0, 1, 0)
        rThumb.Position = UDim2.new(p, 0, 0.5, -8)
        rotVal.Text = math.round(p * 100) .. "%"
        -- recolor every accent background gradient live
        for _, t in ipairs(themed) do
            if t.role == "gradBg" then t.obj.Color = ColorSequence.new(accentBg(), accentBgBottom()) end
        end
        -- top glow opacity tracks strength too (keep _obt synced for open/close)
        topGlow.BackgroundTransparency = glowTrans()
        topGlow:SetAttribute("_obt", glowTrans())
    end

    rHit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            rSliding = true
            updateStrength(i.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if rSliding and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            updateStrength(i.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            rSliding = false
        end
    end)

    -- Info footer
    local footer = new("Frame", {Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = C.card,
        BorderSizePixel = 0, LayoutOrder = 6}, SetP)
    corner(footer, 10)
    stroke(footer, C.border, 1)
    lbl({Size = UDim2.new(1, -24, 1, 0), Position = UDim2.new(0, 12, 0, 0),
        Text = "\u{1F4A1}  Settings apply live & reset on rejoin", TextColor3 = C.muted, TextSize = 10}, footer)

    -- ═══════════════════════════════════════════
    --  LOADING OVERLAY  (lives INSIDE the window)
    -- ═══════════════════════════════════════════
    -- Covers the tabs + content while the pet list builds, then fades to reveal
    -- the UI. The titlebar stays visible above it.
    local loadOverlay = new("Frame", {
        Name = "LoadingOverlay",
        Position = UDim2.new(0, 0, 0, 0), Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, ZIndex = 8, Visible = false,
        Active = true,
    }, Window)
    loadOverlay:SetAttribute("_skipFade", true)  -- opacity controlled manually
    corner(loadOverlay, 14)
    local loGrad = gradient(loadOverlay, accentBg(), accentBgBottom(), 145, true)
    reg(loGrad, "gradBg")

    -- accent glow near the top of the overlay
    local loGlow = new("Frame", {Size = UDim2.new(1, 0, 0, 90), BackgroundColor3 = ACCENT.base,
        BackgroundTransparency = 0.86, BorderSizePixel = 0, ZIndex = 8}, loadOverlay)
    corner(loGlow, 14)
    local loGlowGrad = Instance.new("UIGradient")
    loGlowGrad.Color = ColorSequence.new(ACCENT.base, ACCENT.base)
    loGlowGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1)})
    loGlowGrad.Rotation = 90
    loGlowGrad.Parent = loGlow
    reg(loGlow, "bg")
    reg(loGlowGrad, "gradGlow")

    local loPaw = new("Frame", {Size = UDim2.new(0, 46, 0, 46), Position = UDim2.new(0.5, -23, 0.5, -54),
        BackgroundColor3 = ACCENT.dim, BorderSizePixel = 0, ZIndex = 9}, loadOverlay)
    corner(loPaw, 13)
    local loPawGrad = gradient(loPaw, ACCENT.base, ACCENT.dim, 135)
    reg(loPawGrad, "gradAccent")
    lbl({Size = UDim2.new(1, 0, 1, 0), Text = "\u{1F43E}", TextSize = 24,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 10}, loPaw)

    local loCounter = lbl({Size = UDim2.new(1, -40, 0, 18), Position = UDim2.new(0, 20, 0.5, 6),
        Text = "000 / 000", TextColor3 = ACCENT.light, TextSize = 15, Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 9}, loadOverlay)
    reg(loCounter, "text")

    local loTrack = new("Frame", {Size = UDim2.new(0, 180, 0, 6), Position = UDim2.new(0.5, -90, 0.5, 32),
        BackgroundColor3 = C.off, BorderSizePixel = 0, ZIndex = 9}, loadOverlay)
    corner(loTrack, 3)
    local loBar = new("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = ACCENT.base,
        BorderSizePixel = 0, ZIndex = 10}, loTrack)
    corner(loBar, 3)
    local loBarGrad = gradient(loBar, ACCENT.light, ACCENT.base, 0)
    reg(loBarGrad, "gradAccent")
    reg(loBar, "bg")

    local loStatus = lbl({Size = UDim2.new(1, -40, 0, 14), Position = UDim2.new(0, 20, 0.5, 48),
        Text = "Loading pets\u{2026}", TextColor3 = C.muted, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 9}, loadOverlay)

    -- pulse the paw while the overlay is up
    task.spawn(function()
        while loadOverlay.Parent do
            if loadOverlay.Visible then
                tw(loPaw, {Size = UDim2.new(0, 50, 0, 50), Position = UDim2.new(0.5, -25, 0.5, -56)}, 0.6, Enum.EasingStyle.Sine)
                task.wait(0.62)
                tw(loPaw, {Size = UDim2.new(0, 46, 0, 46), Position = UDim2.new(0.5, -23, 0.5, -54)}, 0.6, Enum.EasingStyle.Sine)
                task.wait(0.62)
            else
                task.wait(0.2)
            end
        end
    end)

    local function loSetProgress(done, total)
        if total <= 0 then total = 1 end
        loCounter.Text = string.format("%03d / %03d", done, total)
        tw(loBar, {Size = UDim2.new(math.clamp(done / total, 0, 1), 0, 1, 0)}, 0.12, Enum.EasingStyle.Quad)
    end

    -- reset the overlay visuals to fully opaque (start of each open)
    local function loResetOpaque()
        loadOverlay.Visible = true
        loGrad.Enabled = gradientsEnabled
        for _, o in ipairs(loadOverlay:GetDescendants()) do
            if o:IsA("TextLabel") then o.TextTransparency = 0 end
            if o:IsA("Frame") then o.BackgroundTransparency = o:GetAttribute("_obt") or 0 end
            if o:IsA("UIStroke") then o.Transparency = o:GetAttribute("_ot") or 0 end
        end
        loadOverlay.BackgroundTransparency = 0
        loCounter.Text = "000 / 000"
        loBar.Size = UDim2.new(0, 0, 1, 0)
        loStatus.Text = "Loading pets\u{2026}"
    end

    -- ═══════════════════════════════════════════
    --  OPEN SEQUENCE
    -- ═══════════════════════════════════════════
    local function showLoadingThenOpen()
        loResetOpaque()
        playOpenAnim()  -- window opens; active panel shown beneath the overlay
        task.delay(0.42, function() if showActivePanel then showActivePanel() end end)

        task.spawn(function()
            task.wait(0.3)  -- let the window finish opening
            if not petListBuilt then
                buildPetList(function(done, total) loSetProgress(done, total) end)
            else
                local total = #petEntries
                local steps = 22
                for s = 1, steps do
                    loSetProgress(math.floor(total * s / steps), total)
                    task.wait(0.012)
                end
            end
            loSetProgress(#petEntries, #petEntries)
            loStatus.Text = "Ready"
            task.wait(0.16)

            -- fade the overlay out -> reveals the UI underneath
            tw(loadOverlay, {BackgroundTransparency = 1}, 0.3)
            for _, o in ipairs(loadOverlay:GetDescendants()) do
                if o:IsA("TextLabel") then tw(o, {TextTransparency = 1}, 0.26) end
                if o:IsA("Frame") and o.BackgroundTransparency < 1 then tw(o, {BackgroundTransparency = 1}, 0.26) end
                if o:IsA("UIStroke") then tw(o, {Transparency = 1}, 0.26) end
            end
            task.delay(0.34, function() loadOverlay.Visible = false end)
        end)
    end

    -- ═══════════════════════════════════════════
    --  REOPEN BUTTON
    -- ═══════════════════════════════════════════
    ReopenBtn = new("Frame", {
        Name = "PetSpawnerReopen",
        Size = UDim2.new(0, 48, 0, 48), Position = UDim2.new(0, 14, 0, 70),
        BackgroundColor3 = ACCENT.dim, BorderSizePixel = 0, ZIndex = 10,
        Active = true, Visible = false,
    }, ScreenGui)
    corner(ReopenBtn, 12)
    reg(ReopenBtn, "bgDim")
    local rGrad = gradient(ReopenBtn, ACCENT.light, ACCENT.base, 135, true)
    reg(rGrad, "gradAccent")
    local rStroke = stroke(ReopenBtn, ACCENT.base, 1.5)
    reg(rStroke, "stroke")
    lbl({Size = UDim2.new(1, 0, 1, 0), Text = "\u{1F43E}", TextSize = 22,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 11}, ReopenBtn)
    task.spawn(function()
        while ReopenBtn.Parent do
            tw(rStroke, {Transparency = 0.6}, 0.85, Enum.EasingStyle.Sine)
            task.wait(0.85)
            tw(rStroke, {Transparency = 0}, 0.85, Enum.EasingStyle.Sine)
            task.wait(0.85)
        end
    end)
    local rClick = new("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 12}, ReopenBtn)
    do
        local rDrag = false
        local rDragStart, rStartPos
        local rDragMoved = false
        rClick.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                rDrag = true; rDragMoved = false; rDragStart = i.Position; rStartPos = ReopenBtn.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if not rDrag then return end
            if i.UserInputType ~= Enum.UserInputType.MouseMovement and i.UserInputType ~= Enum.UserInputType.Touch then return end
            local d = i.Position - rDragStart
            if math.abs(d.X) > 5 or math.abs(d.Y) > 5 then rDragMoved = true end
            if rDragMoved then
                local vp = Camera.ViewportSize
                ReopenBtn.Position = UDim2.new(
                    0, math.clamp(rStartPos.X.Offset + d.X, 0, vp.X - 48),
                    0, math.clamp(rStartPos.Y.Offset + d.Y, 0, vp.Y - 48))
            end
        end)
        rClick.InputEnded:Connect(function(i)
            if i.UserInputType ~= Enum.UserInputType.MouseButton1 and i.UserInputType ~= Enum.UserInputType.Touch then return end
            local wasDrag = rDragMoved
            rDrag = false; rDragMoved = false
            if not wasDrag then playClick() ReopenBtn.Visible = false showLoadingThenOpen() end
        end)
    end

    -- ═══════════════════════════════════════════
    --  KICK OFF
    -- ═══════════════════════════════════════════
    Window.Visible = false
    showLoadingThenOpen()
    print("\u{2713} Pet Spawner \u{2014} macOS UI loaded")
end)
