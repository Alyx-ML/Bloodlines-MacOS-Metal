loc_1032C402,2,;jne loc_1032C429 ; vtmb-tweaks bNoCorpseDespawn: never start the corpse fade timer|tcall loc_1032C429|endp|proc loc_1032C402_after
loc_10265D72,5,;call loc_10011667 ; vtmb-tweaks bNoCorpseDespawn: fade out on death only for CNPC_VRat (vtable 0x104C558C)|load tmp0, ecx, 1|mov tmp1, loc_104C558C|cmoveq tmp0, tmp1, tmpcnd, 0, 1|ctcallz tmpcnd, loc_10265D72_fade|tcall loc_10265D72_after|endp|proc loc_10265D72_fade|PUSH loc_10265D72_after|tcall loc_10011667|endp|proc loc_10265D72_after
loc_1032BA84,5,;call loc_10005E0C ; vtmb-tweaks bNPCsDropAllWeapons (runtime/bl_vampire.c)|call bl_vampire_DropAllWeapons $
loc_10154E93,3,;and ecx, 0x1 ; vtmb-tweaks bNonSolidRagdolls: c_ragdoll_prop ragdolls always in the debris collision group|mov ecx, 1
loc_1032D142,2,;mov eax, [edi] ; vtmb-tweaks bStackableWeapons: drop one of a stack, not the active weapon itself|call bl_vampire_ShouldDropActive $|ctcallz eax, loc_1032D16F|tcall loc_1032D142_keep|endp|proc loc_1032D142_keep|load eax, edi, 1
loc_1017788C,5,;call loc_100138D6 ; vtmb-tweaks bStackableWeapons: switch weapons only when none is active|call bl_vampire_SwitchToNextBest $
loc_1017724E,5,;call loc_100151B8 ; vtmb-tweaks bStackableWeapons: a stackable weapon can be picked up when owned|call bl_vampire_OwnsThisType $
loc_100D2DC1,5,;call loc_10431447 ; vtmb-tweaks fov reset fix: remember the field of view the fov command sets|call bl_vampire_SetFov $
loc_10239E01,6,;mov [edi+0x1e78], ebx ; vtmb-tweaks fov reset fix: zooming out restores it|call bl_vampire_ZoomOutFov $
loc_1016C5BE,6,;mov eax, [ebx+0x6f0] ; Griffith Park frenzy fix: track the frenzying player, their FrenzyShadow and the werewolf (runtime/bl_vampire.c)|PUSH loc_10482FE4|PUSH loc_1049D8C0|PUSH loc_104CF4D4|PUSH loc_104B2184|PUSH loc_1070B228|PUSH loc_10566458|call bl_vampire_WolfWatch $|add tmpadr, ebx, 1776|load eax, tmpadr, 1
loc_1026AD63,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_1026EB35,1,;push edx ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH edx|call bl_vampire_WolfTrace $
loc_102A9AEB,1,;push edx ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH edx|call bl_vampire_WolfTrace $
loc_102E362C,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_102E38A3,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_103CBB55,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_103CBC4E,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_103CBD2F,1,;push eax ; Griffith Park frenzy fix: the werewolf's movement trace skips the player's body and hits the FrenzyShadow|PUSH eax|call bl_vampire_WolfTrace $
loc_1026E840,1,;push ecx ; Griffith Park frenzy fix: the player's body is never the werewolf's ground entity|PUSH ecx|call bl_vampire_WolfGround $
loc_100D6DD8,1,;pop edi ; history-stat-reset-fix: after the History is set, reset the stats and point pool and set it again (runtime/bl_vampire.c)|PUSH loc_1074F028|call bl_vampire_HistoryReset $|POP edi
loc_100D6DEB,1,;pop edi ; history-stat-reset-fix: the same when the History is cleared|PUSH loc_1074F028|call bl_vampire_HistoryResetNone $|POP edi
loc_10206AD1,8,;cmp ebx, ebp; je loc_10206BCF ; history-stat-reset-fix: applying the History it already has goes ahead once, for the reset|call bl_vampire_HistorySame $|ctcallz ecx, loc_10206AD1_go|tcall loc_10206BCF|endp|proc loc_10206AD1_go
loc_1016C558,6,;mov al, [ebp+0x1edc] ; protean-improved Warform Frenzy: in the player's think, Warform counts as off while the player frenzies (runtime/bl_vampire.c)|call bl_vampire_WarformFlag $
loc_1033E9BE,5,;push 0x1869f ; protean-improved Warform Frenzy: the Protean command does not end a frenzy|call bl_vampire_FrenzyKeep $|POP tmp0|ctcallz tmp0, loc_1033E9BE_go|tcall loc_1033E9D4|endp|proc loc_1033E9BE_go|PUSH 0x1869f
loc_101F9177,6,;mov edi, [ebp+0xa8] ; protean-improved Warform Frenzy: Protean 5 during a frenzy uses the FrenzyShadow, no second controller|add tmpadr, ebp, 168|load edi, tmpadr, 1|PUSH loc_10750CB4|PUSH loc_1070B228|PUSH loc_10566458|call bl_vampire_WarformShadow $|POP tmp0|ctcallz tmp0, loc_101F9177_go|tcall loc_101F8FA3|endp|proc loc_101F9177_go
loc_103510D7,8,;cmp [edi+0x1edc], cl; jne loc_10351131 ; protean-improved Warform Frenzy: a frenzy counts as the Warform state it compares|call bl_vampire_WarformSame $|POP tmp0|ctcallz tmp0, loc_10351131|tcall loc_103510D7_same|endp|proc loc_103510D7_same
loc_101E56E0,5,;sub esp, 0x10; push ebx; push esi ; protean-improved Warform Frenzy: the FrenzyShadow's owner stands for the player|PUSH loc_104B2184|PUSH loc_10566458|call bl_vampire_WarformTarget $|sub esp, esp, 16|PUSH ebx|PUSH esi
loc_101E5B30,7,;sub esp, 0xc; mov edx, [esp+0x10] ; protean-improved Warform Frenzy: the same|PUSH loc_104B2184|PUSH loc_10566458|call bl_vampire_WarformTarget $|sub esp, esp, 12|add tmpadr, esp, 16|load edx, tmpadr, 1
loc_1033ED73,4,;test cl, cl; je loc_1033ED9E ; protean-improved Warform Frenzy: this check always skips (the plugin's je to jmp)|tcall loc_1033ED9E|endp|proc loc_1033ED73_after
loc_1022C50F,5,;call loc_10001226 ; subtitle-pause-fix: CPropRadio::Activate's CBaseEntity::Activate also restarts the station's record (bl_vampire_RadioActivate, runtime/bl_subtitle.c)|PUSH loc_10566458|PUSH loc_1070B228|call bl_vampire_RadioActivate $
loc_1022C807,5,;call loc_10002874 ; subtitle-pause-fix: the radio's SetFakeSilence keeps the broadcast going while it is off (bl_vampire_RadioSilence)|PUSH loc_10566458|PUSH loc_1070B228|call bl_vampire_RadioSilence $
