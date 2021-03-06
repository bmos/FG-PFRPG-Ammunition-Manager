--
-- Please see the LICENSE.md file included with this distribution for attribution and copyright information.
--

tLoadWeapons = { 'firearm', 'crossbow', 'javelin', 'ballista', 'windlass', 'pistol', 'rifle', 'sling', 'loadaction' }

local function isFragile(nodeWeapon)
	local sWeaponProperties = DB.getValue(nodeWeapon, 'properties', ''):lower()
	local bIsFragile = (sWeaponProperties:find('fragile') or 0) > 0
	local bIsMasterwork = sWeaponProperties:find('masterwork') or false
	local bIsBone = sWeaponProperties:find('bone') or false
	local bIsMagic = DB.getValue(nodeWeapon, 'bonus', 0) > 0
	return (bIsFragile and not bIsMagic and (not bIsMasterwork or bIsBone))
end

--	tick off used ammunition, count misses, post 'out of ammo' chat message
local function breakWeapon(rSource, nodeWeapon, sWeaponName)
	if nodeWeapon and isFragile(nodeWeapon) then
		local nBroken = DB.getValue(nodeWeapon, 'broken', 0)
		local nItemHitpoints = DB.getValue(nodeWeapon, 'hitpoints', 0)
		local nItemDamage = DB.getValue(nodeWeapon, 'itemdamage', 0)
		if nBroken == 0 then
			DB.setValue(nodeWeapon, 'broken', 'number', 1)
			DB.setValue(nodeWeapon, 'itemdamage', 'number', math.floor(nItemHitpoints / 2) + math.max(nItemDamage, 1))
			ChatManager.Message(string.format(Interface.getString('char_actions_fragile_broken'), sWeaponName), true, rSource);
		elseif nBroken == 1 then
			DB.setValue(nodeWeapon, 'broken', 'number', 2)
			DB.setValue(nodeWeapon, 'itemdamage', 'number', nItemHitpoints + math.max(nItemDamage, 1))
			ChatManager.Message(string.format(Interface.getString('char_actions_fragile_destroyed'), sWeaponName), true, rSource);
		end
	end
end

--	tick off used ammunition, count misses, post 'out of ammo' chat message
function ammoTracker(rSource, sDesc, sResult)
	local sWeaponName = sDesc:gsub('%[ATTACK %(%u%)%]', '');
	sWeaponName = sWeaponName:gsub('%[ATTACK #%d+ %(%u%)%]', '');
	sWeaponName = sWeaponName:gsub('%[%u+%]', '');
	sWeaponName = sWeaponName:gsub('%[.+%]', '');
	sWeaponName = sWeaponName:gsub(' %(vs%. .+%)', '');
	sWeaponName = StringManager.trim(sWeaponName);
	if not sDesc:match('%[CONFIRM%]') and sWeaponName ~= '' then
		local nodeWeaponList = DB.findNode(rSource.sCreatureNode .. '.weaponlist');
		for _,nodeWeapon in pairs(nodeWeaponList.getChildren()) do
			local sWeaponNameFromNode = DB.getValue(nodeWeapon, 'name', '')
			sWeaponNameFromNode = sWeaponNameFromNode:gsub('%[%u+%]', '');
			sWeaponNameFromNode = sWeaponNameFromNode:gsub('%[.+%]', '');
			sWeaponNameFromNode = StringManager.trim(sWeaponNameFromNode)
			if sWeaponNameFromNode == sWeaponName then
				if sResult == "fumble" then -- break fragile weapon on natural 1
					local _,sWeaponNode = DB.getValue(nodeWeapon, 'shortcut', '')
					local nodeWeaponLink = DB.findNode(sWeaponNode)
					breakWeapon(rSource, nodeWeaponLink, sWeaponName)
				end
				if sDesc:match('%[ATTACK %(R%)%]') or sDesc:match('%[ATTACK #%d+ %(R%)%]') then
					local nMaxAmmo = DB.getValue(nodeWeapon, 'maxammo', 0);
					local nAmmoUsed = DB.getValue(nodeWeapon, 'ammo', 0) + 1;

					local bInfiniteAmmo
					if sRuleset == "PFRPG" or sRuleset == "3.5E" then
						bInfiniteAmmo = EffectManager35E.hasEffectCondition(rSource, 'INFAMMO')
					elseif sRuleset == "4E" then
						bInfiniteAmmo = EffectManager4E.hasEffectCondition(rSource, 'INFAMMO')
					end

					if nMaxAmmo ~= 0 and not bInfiniteAmmo then
						if nAmmoUsed == nMaxAmmo then
							ChatManager.Message(string.format(Interface.getString('char_actions_usedallammo'), sWeaponName), true, rSource);
							DB.setValue(nodeWeapon, 'ammo', 'number', nAmmoUsed);
						else
							DB.setValue(nodeWeapon, 'ammo', 'number', nAmmoUsed);
						end

						if sResult == 'miss' or sResult == 'fumble' then -- counting misses
							DB.setValue(nodeWeapon, 'missedshots', 'number', DB.getValue(nodeWeapon, 'missedshots', 0) + 1);
						end
					end
				end
			end
		end
	end
end

--	calculate how much attacks hit/miss by
function calculateMargin(nDC, nTotal)
	if nDC and nTotal then
		local nMargin = 0
		if (nTotal - nDC) > 0 then
			nMargin = nTotal - nDC
		elseif (nTotal - nDC) < 0 then
			nMargin = nDC - nTotal
		end
		nMargin = math.floor(nMargin / 5) * 5

		if nMargin > 0 then return nMargin; end
	end
end

local function onAttack_pfrpg(rSource, rTarget, rRoll)
	local rMessage = ActionsManager.createActionMessage(rSource, rRoll);

	local bIsSourcePC = ActorManager.isPC(rSource);
	local bAllowCC = OptionsManager.isOption("HRCC", "on") or (not bIsSourcePC and OptionsManager.isOption("HRCC", "npc"));

	if rRoll.sDesc:match("%[CMB") then
		rRoll.sType = "grapple";
	end

	local rAction = {};
	rAction.nTotal = ActionsManager.total(rRoll);
	rAction.aMessages = {};

	-- If we have a target, then calculate the defense we need to exceed
	local nDefenseVal, nAtkEffectsBonus, nDefEffectsBonus, nMissChance;
	if rRoll.sType == "critconfirm" then
		local sDefenseVal = rRoll.sDesc:match(" %[AC (%d+)%]");
		if sDefenseVal then
			nDefenseVal = tonumber(sDefenseVal);
		end
		nMissChance = tonumber(rRoll.sDesc:match("%[MISS CHANCE (%d+)%%%]")) or 0;
		rMessage.text = rMessage.text:gsub(" %[AC %d+%]", "");
		rMessage.text = rMessage.text:gsub(" %[MISS CHANCE %d+%%%]", "");
	else
		nDefenseVal, nAtkEffectsBonus, nDefEffectsBonus, nMissChance = ActorManager35E.getDefenseValue(rSource, rTarget, rRoll);
		if nAtkEffectsBonus ~= 0 then
			rAction.nTotal = rAction.nTotal + nAtkEffectsBonus;
			local sFormat = "[" .. Interface.getString("effects_tag") .. " %+d]";
			table.insert(rAction.aMessages, string.format(sFormat, nAtkEffectsBonus));
		end
		if nDefEffectsBonus ~= 0 then
			nDefenseVal = nDefenseVal + nDefEffectsBonus;
			local sFormat = "[" .. Interface.getString("effects_def_tag") .. " %+d]";
			table.insert(rAction.aMessages, string.format(sFormat, nDefEffectsBonus));
		end
	end
	
	-- for compatibility with mirror image handler, add this here in your onAttack function
	-- Get the misfire threshold
	if MirrorImageHandler then
		local sMisfireRange = string.match(rRoll.sDesc, "%[MISFIRE (%d+)%]");
		if sMisfireRange then
			rAction.nMisfire = tonumber(sMisfireRange) or 0;
		end
	end
	-- end compatibility with mirror image handler
	
	-- Get the crit threshold
	rAction.nCrit = 20;
	local sAltCritRange = string.match(rRoll.sDesc, "%[CRIT (%d+)%]");
	if sAltCritRange then
		rAction.nCrit = tonumber(sAltCritRange) or 20;
		if (rAction.nCrit <= 1) or (rAction.nCrit > 20) then
			rAction.nCrit = 20;
		end
	end

	rAction.nFirstDie = 0;
	if #(rRoll.aDice) > 0 then
		rAction.nFirstDie = rRoll.aDice[1].result or 0;
	end
	rAction.bCritThreat = false;
	if rAction.nFirstDie >= 20 then
		rAction.bSpecial = true;
		if rRoll.sType == "critconfirm" then
			rAction.sResult = "crit";
			table.insert(rAction.aMessages, "[CRITICAL HIT]");
		elseif rRoll.sType == "attack" then
			if bAllowCC then
				rAction.sResult = "hit";
				rAction.bCritThreat = true;
				table.insert(rAction.aMessages, "[AUTOMATIC HIT]");
			else
				rAction.sResult = "crit";
				table.insert(rAction.aMessages, "[CRITICAL HIT]");
			end
		else
			rAction.sResult = "hit";
			table.insert(rAction.aMessages, "[AUTOMATIC HIT]");
		end
	elseif rAction.nFirstDie == 1 then
		if rRoll.sType == "critconfirm" then
			table.insert(rAction.aMessages, "[CRIT NOT CONFIRMED]");
			rAction.sResult = "miss";
		else

			-- for compatibility with mirror image handler, add this here in your onAttack function
			if MirrorImageHandler and rAction.nMisfire and rRoll.sType == "attack" then
				table.insert(rAction.aMessages, "[MISFIRE]");
				rAction.sResult = "miss";
			else
			-- end compatibility with mirror image handler

				table.insert(rAction.aMessages, "[AUTOMATIC MISS]");
				rAction.sResult = "fumble";
			end
		end

	-- for compatibility with mirror image handler, add this here in your onAttack function
	elseif MirrorImageHandler and rAction.nMisfire and rAction.nFirstDie <= rAction.nMisfire and rRoll.sType == "attack" then
		table.insert(rAction.aMessages, "[MISFIRE]");
		rAction.sResult = "miss";
	-- end compatibility with mirror image handler

	elseif nDefenseVal then
		if rAction.nTotal >= nDefenseVal then
			if rRoll.sType == "critconfirm" then
				rAction.sResult = "crit";
				table.insert(rAction.aMessages, "[CRITICAL HIT]");
			elseif rRoll.sType == "attack" and rAction.nFirstDie >= rAction.nCrit then
				if bAllowCC then
					rAction.sResult = "hit";
					rAction.bCritThreat = true;
					table.insert(rAction.aMessages, "[CRITICAL THREAT]");
				else
					rAction.sResult = "crit";
					table.insert(rAction.aMessages, "[CRITICAL HIT]");
				end
			else
				rAction.sResult = "hit";
				table.insert(rAction.aMessages, "[HIT]");
			end
		else
			rAction.sResult = "miss";
			if rRoll.sType == "critconfirm" then
				table.insert(rAction.aMessages, "[CRIT NOT CONFIRMED]");
			else
				table.insert(rAction.aMessages, "[MISS]");
			end
		end
	elseif rRoll.sType == "critconfirm" then
		rAction.sResult = "crit";
		table.insert(rAction.aMessages, "[CHECK FOR CRITICAL]");
	elseif rRoll.sType == "attack" and rAction.nFirstDie >= rAction.nCrit then
		if bAllowCC then
			rAction.sResult = "hit";
			rAction.bCritThreat = true;
		else
			rAction.sResult = "crit";
		end
		table.insert(rAction.aMessages, "[CHECK FOR CRITICAL]");
	end

	if ((rRoll.sType == "critconfirm") or not rAction.bCritThreat) and (nMissChance > 0) then
		table.insert(rAction.aMessages, "[MISS CHANCE " .. nMissChance .. "%]");
	end

	--	bmos adding hit margin tracking
	--	for compatibility with ammunition tracker, add this here in your onAttack function
	if AmmunitionManager then
		local nHitMargin = AmmunitionManager.calculateMargin(nDefenseVal, rAction.nTotal)
		if nHitMargin then table.insert(rAction.aMessages, "[BY " .. nHitMargin .. "+]") end
	end
	--	end bmos adding hit margin tracking

	Comm.deliverChatMessage(rMessage);

	if rAction.sResult == "crit" then
		ActionAttack.setCritState(rSource, rTarget);
	end

	local bRollMissChance = false;
	if rRoll.sType == "critconfirm" then
		bRollMissChance = true;
	else
		if rAction.bCritThreat then
			local rCritConfirmRoll = { sType = "critconfirm", aDice = {"d20"}, bTower = rRoll.bTower, bSecret = rRoll.bSecret };
				
			local nCCMod = EffectManager35E.getEffectsBonus(rSource, {"CC"}, true, nil, rTarget);
			if nCCMod ~= 0 then
				rCritConfirmRoll.sDesc = string.format("%s [CONFIRM %+d]", rRoll.sDesc, nCCMod);
			else
				rCritConfirmRoll.sDesc = rRoll.sDesc .. " [CONFIRM]";
			end
			if nMissChance > 0 then
				rCritConfirmRoll.sDesc = rCritConfirmRoll.sDesc .. " [MISS CHANCE " .. nMissChance .. "%]";
			end
			rCritConfirmRoll.nMod = rRoll.nMod + nCCMod;

			if nDefenseVal then
				rCritConfirmRoll.sDesc = rCritConfirmRoll.sDesc .. " [AC " .. nDefenseVal .. "]";
			end

			if nAtkEffectsBonus and nAtkEffectsBonus ~= 0 then
				local sFormat = "[" .. Interface.getString("effects_tag") .. " %+d]";
				rCritConfirmRoll.sDesc = rCritConfirmRoll.sDesc .. " " .. string.format(sFormat, nAtkEffectsBonus);
			end

			ActionsManager.roll(rSource, { rTarget }, rCritConfirmRoll, true);
		elseif (rAction.sResult ~= "miss") and (rAction.sResult ~= "fumble") then
			bRollMissChance = true;

		-- for compatibility with mirror image handler, add this here in your onAttack function 
		elseif MirrorImageHandler and (rAction.sResult == "miss") and (nDefenseVal - rAction.nTotal <= 5) then
			bRollMissChance = true;
			nMissChance = 0;
		-- end compatibility with mirror image handler

		end
	end
	if bRollMissChance and (nMissChance > 0) then
		local aMissChanceDice = { "d100" };
		if not UtilityManager.isClientFGU() then
			table.insert(aMissChanceDice, "d10");
		end
		local sMissChanceText;
		sMissChanceText = string.gsub(rMessage.text, " %[CRIT %d+%]", "");
		sMissChanceText = string.gsub(sMissChanceText, " %[CONFIRM%]", "");
		local rMissChanceRoll = { sType = "misschance", sDesc = sMissChanceText .. " [MISS CHANCE " .. nMissChance .. "%]", aDice = aMissChanceDice, nMod = 0 };
		ActionsManager.roll(rSource, rTarget, rMissChanceRoll);

	-- for compatibility with mirror image handler, add this here in your onAttack function
	elseif MirrorImageHandler and bRollMissChance then
		local nMirrorImageCount = MirrorImageHandler.getMirrorImageCount(rTarget);
		if nMirrorImageCount > 0 then
			if rAction.sResult == "hit" or rAction.sResult == "crit" then
				local rMirrorImageRoll = MirrorImageHandler.getMirrorImageRoll(nMirrorImageCount, rRoll.sDesc);
				ActionsManager.roll(rSource, rTarget, rMirrorImageRoll);
			elseif rRoll.sType ~= "critconfirm" then
				MirrorImageHandler.removeImage(rSource, rTarget);
				table.insert(rAction.aMessages, "[MIRROR IMAGE REMOVED BY NEAR MISS]");
			end
		end
	-- end compatibility with mirror image handler

	end

	--	bmos adding automatic ammunition ticker and chat messaging
	--	for compatibility with ammunition tracker, add this here in your onAttack function
	if AmmunitionManager and bIsSourcePC then AmmunitionManager.ammoTracker(rSource, rRoll.sDesc, rAction.sResult) end
	--	end bmos adding automatic ammunition ticker and chat messaging

	if rTarget then
		ActionAttack.notifyApplyAttack(rSource, rTarget, rRoll.bTower, rRoll.sType, rRoll.sDesc, rAction.nTotal, table.concat(rAction.aMessages, " "));

		-- REMOVE TARGET ON MISS OPTION
		if (rAction.sResult == "miss" or rAction.sResult == "fumble") and rRoll.sType ~= "critconfirm" and not string.match(rRoll.sDesc, "%[FULL%]") then
			local bRemoveTarget = false;
			if OptionsManager.isOption("RMMT", "on") then
				bRemoveTarget = true;
			elseif rRoll.bRemoveOnMiss then
				bRemoveTarget = true;
			end

			if bRemoveTarget then
				TargetingManager.removeTarget(ActorManager.getCTNodeName(rSource), ActorManager.getCTNodeName(rTarget));
			end
		end
	end

	-- HANDLE FUMBLE/CRIT HOUSE RULES
	local sOptionHRFC = OptionsManager.getOption("HRFC");
	if rAction.sResult == "fumble" and ((sOptionHRFC == "both") or (sOptionHRFC == "fumble")) then
		ActionAttack.notifyApplyHRFC("Fumble");
	end
	if rAction.sResult == "crit" and ((sOptionHRFC == "both") or (sOptionHRFC == "criticalhit")) then
		ActionAttack.notifyApplyHRFC("Critical Hit");
	end
end

local function onAttack_4e(rSource, rTarget, rRoll)
	local rMessage = ActionsManager.createActionMessage(rSource, rRoll);

	local rAction = {};
	rAction.nTotal = ActionsManager.total(rRoll);
	rAction.aMessages = {};
	
	-- If we have a target, then calculate the defense we need to exceed
	local nDefenseVal, nAtkEffectsBonus, nDefEffectsBonus = ActorManager4E.getDefenseValue(rSource, rTarget, rRoll);
	if nAtkEffectsBonus ~= 0 then
		rAction.nTotal = rAction.nTotal + nAtkEffectsBonus;
		local sFormat = "[" .. Interface.getString("effects_tag") .. " %+d]"
		table.insert(rAction.aMessages, string.format(sFormat, nAtkEffectsBonus));
	end
	if nDefEffectsBonus ~= 0 then
		nDefenseVal = nDefenseVal + nDefEffectsBonus;
		local sFormat = "[" .. Interface.getString("effects_def_tag") .. " %+d]"
		table.insert(rAction.aMessages, string.format(sFormat, nDefEffectsBonus));
	end

	-- Get the crit threshold
	rAction.nCrit = 20;	
	local sAltCritRange = string.match(rRoll.sDesc, "%[CRIT (%d+)%]");
	if sAltCritRange then
		rAction.nCrit = tonumber(sAltCritRange) or 20;
		if (rAction.nCrit <= 1) or (rAction.nCrit > 20) then
			rAction.nCrit = 20;
		end
	end
	
	rAction.nFirstDie = 0;
	if #(rRoll.aDice) > 0 then
		rAction.nFirstDie = rRoll.aDice[1].result or 0;
	end
	if rAction.nFirstDie >= 20 then
		rAction.bSpecial = true;
		if nDefenseVal then
			if rAction.nTotal >= nDefenseVal then
				rAction.sResult = "crit";
				table.insert(rAction.aMessages, "[CRITICAL HIT]");
			else
				rAction.sResult = "hit";
				table.insert(rAction.aMessages, "[AUTOMATIC HIT]");
			end
		else
			table.insert(rAction.aMessages, "[AUTOMATIC HIT, CHECK FOR CRITICAL]");
		end
	elseif rAction.nFirstDie == 1 then
		rAction.sResult = "fumble";
		table.insert(rAction.aMessages, "[AUTOMATIC MISS]");
	elseif nDefenseVal then
		if rAction.nTotal >= nDefenseVal then
			if rAction.nFirstDie >= rAction.nCrit then
				rAction.sResult = "crit";
				table.insert(rAction.aMessages, "[CRITICAL HIT]");
			else
				rAction.sResult = "hit";
				table.insert(rAction.aMessages, "[HIT]");
			end
		else
			rAction.sResult = "miss";
			table.insert(rAction.aMessages, "[MISS]");
		end
	elseif rAction.nFirstDie >= rAction.nCrit then
		rAction.sResult = "crit";
		table.insert(rAction.aMessages, "[CHECK FOR CRITICAL]");
	end

	--	bmos adding hit margin tracking
	--	for compatibility with ammunition tracker, add this here in your onAttack function
	if AmmunitionManager then
		local nHitMargin = AmmunitionManager.calculateMargin(nDefenseVal, rAction.nTotal)
		if nHitMargin then table.insert(rAction.aMessages, "[BY " .. nHitMargin .. "+]") end
	end
	--	end bmos adding hit margin tracking

	Comm.deliverChatMessage(rMessage);
	
	--	bmos adding automatic ammunition ticker and chat messaging
	--	for compatibility with ammunition tracker, add this here in your onAttack function
	if AmmunitionManager and ActorManager.isPC(rSource) then AmmunitionManager.ammoTracker(rSource, rRoll.sDesc, rAction.sResult) end
	--	end bmos adding automatic ammunition ticker and chat messaging

	if rTarget then
		ActionAttack.notifyApplyAttack(rSource, rTarget, rRoll.bTower, rRoll.sType, rRoll.sDesc, rAction.nTotal, table.concat(rAction.aMessages, " "));
	end
		
	-- TRACK CRITICAL STATE
	if rAction.sResult == "crit" then
		ActionAttack.setCritState(rSource, rTarget);
	end
		
	-- REMOVE TARGET ON MISS OPTION
	if rTarget then
		if (rAction.sResult == "miss") or (rAction.sResult == "fumble") then
			local bRemoveTarget = false;
			if OptionsManager.isOption("RMMT", "on") then
				bRemoveTarget = true;
			elseif string.match(rRoll.sDesc, "%[RM%]") then
				bRemoveTarget = true;
			end
			
			if bRemoveTarget then
				TargetingManager.removeTarget(ActorManager.getCTNodeName(rSource), ActorManager.getCTNodeName(rTarget));
			end
		end
	end
	
	-- HANDLE FUMBLE/CRIT HOUSE RULES
	local sOptionHRFC = OptionsManager.getOption("HRFC");
	if rAction.sResult == "fumble" and ((sOptionHRFC == "both") or (sOptionHRFC == "fumble")) then
		ActionAttack.notifyApplyHRFC("Fumble");
	end
	if rAction.sResult == "crit" and ((sOptionHRFC == "both") or (sOptionHRFC == "criticalhit")) then
		ActionAttack.notifyApplyHRFC("Critical Hit");
	end
	
end

-- Function Overrides
function onInit()
	-- remove original result handlers
	ActionsManager.unregisterResultHandler("attack");

	-- register new result handlers
	local sRuleset = User.getRulesetName()
	if sRuleset == "PFRPG" or sRuleset == "3.5E" then
		ActionsManager.registerResultHandler("attack", onAttack_pfrpg);
	elseif sRuleset == "4E" then
		ActionsManager.registerResultHandler("attack", onAttack_4e);
	end
end