# Santa Monica: where each quest's unfinished states send the player.
# quest title: {state: (map, target)}, target an entity's targetname or an (x, y, z) origin.
# Covers every quest in vdata/system/quests_santamonica.txt, including the ones whose
# steps happen outside Santa Monica (Muddy, Serial, Ming, Strauss, BertramCD, Hunter).
SANTA_MONICA = {
    "Arthur Knox": {  # A Bounty For The Hunter
        1: ("sm_apartment_1", "Carson_Computer"),   # hack Carson's computer
        2: ("sm_tattoo", "Stan_Gimble"),            # answer the parlor phone
        3: ("sm_bailbonds_1", "Arthur"),            # report back
        4: ("sm_bailbonds_1", "Arthur"),            # collect your pay
        6: ("sm_basement_1", "Stan_Gimble"),        # visit Gimble's shop
    },
    "Bail Jumper": {  # Jumpin' The Bail
        1: ("sm_pawnshop_1", "answering_machine_button"),  # play Marian's messages
        2: ("sm_bailbonds_1", "Arthur"),            # report back
    },
    "Knox Asian": {  # The Hunted Hunter
        1: ("sm_bailbonds_1", (3299.8, 930.16, -283.779)),  # look up the license on the Krime-Puter
        2: ("sm_bailbonds_1", (3299.8, 930.16, -283.779)),  # look up the license on the Krime-Puter
        3: ("sm_asylum_1", (-748.0, 396.0, -277.0)),        # tell Knox (in the Asylum by now)
        5: ("sm_bailbonds_1", (3299.8, 930.16, -283.779)),  # look up the license on the Krime-Puter
        7: ("sm_vamparena", "AsianVamp"),           # kill the vampire at Foxy Boxes
        9: ("sm_medical_1", "morgue_trunk"),        # search Virgil's things in the morgue
        10: ("sm_medical_1", "morgue_trunk"),       # search Virgil's things in the morgue
    },
    "Lily": {  # Thinned Blood
        1: ("sm_diner_1", "Doris"),                 # ask Doris about Lily
        2: ("sm_medical_1", "Lily"),                # free Lily at the blood bank
        3: ("sm_pier_1", "E"),                      # tell E
        7: ("sm_bailbonds_1", (3299.8, 930.16, -283.779)),  # look up the bail bond
        9: ("sm_hub_1", "diary"),                   # open Rolf's car trunk
        11: ("sm_hub_1", "diary"),                  # open Rolf's car trunk
    },
    "Release the Spirit": {  # Spiritual Release
        1: ("sm_oceanhouse_2", "pendant"),          # find the locket
    },
    "Werewolf Blood": {  # Bloody Mess
        1: ("sm_medical_1", "garou_blood"),         # take the blood sample
        2: ("sm_pawnshop_1", "Mailbox_haven"),      # mail it from your haven
        3: ("sm_pawnshop_1", "Mailbox_haven"),      # collect the reward
    },
    "Danielle": {  # Replanting A Lily
        1: ("sm_asylum_1", "Danielle"),             # talk Danielle into it
        2: ("sm_medical_1", "Vandal"),              # report to Vandal
        4: ("sm_medical_1", "Vandal"),              # report to Vandal
        5: ("sm_asylum_1", "Danielle"),             # find another donor
        7: ("sm_medical_1", "Vandal"),              # report to Vandal
    },
    "Morphine": {  # The Pain Of Being Mercurio
        1: ("sm_medical_1", "pill1"),               # take the clinic morphine
        2: ("sm_apartment_1", "Mercurio"),          # give it to Mercurio
    },
    "Serial": {  # Carnival Of Death
        1: ("sm_pier_1", "murder_scene_trigger"),   # look at the pier murder
        2: ("la_abandoned_building_1", "Bum"),      # next victim downtown; ask the bum
        3: ("la_abandoned_building_1", "murder_key"),  # take the motel key
        4: ("la_abandoned_building_1", "murder_key"),  # take the motel key
        5: ("la_abandoned_building_1", "murder_key"),  # take the motel key
        6: ("hw_luckystar_1", "killer_card"),       # take the business card
        7: ("sm_junkyard_1", "Killer"),             # face the killer
        11: ("la_abandoned_building_1", "Bum"),     # next victim downtown; ask the bum
    },
    "Muddy": {  # Mudd Hunt
        1: ("la_skyline_1", "victim_answering_machine"),  # play Milton's messages
        2: ("la_abandoned_building_1", "murder_key"),     # search the warehouse
        3: ("hw_luckystar_1", "KillerLock"),        # open the motel room
    },
    "Mercurio": {  # Wherefore Art Thou, Mercurio?
        1: ("sm_apartment_1", "Mercurio"),          # meet Mercurio
    },
    "Astrolite": {  # Surf's Up
        1: ("sm_beachhouse_1", "astrolite"),        # get the Astrolite
        2: ("sm_apartment_1", "Mercurio"),          # return to Mercurio
        4: ("sm_beachhouse_1", "astrolite"),        # get the Astrolite
        5: ("sm_apartment_1", "Mercurio"),          # return to Mercurio
        6: ("sm_apartment_1", "mercurio_journal"),  # read his journal
    },
    "Warehouse": {  # Explosive Beginning
        1: ("sm_warehouse_1", (112.5, 560.0, -42.7)),  # plant the bomb
        2: ("sm_asylum_1", "Therese"),              # end the feud
        3: ("sm_hub_1", "Bertram"),                 # meet Tung
        4: ("sm_hub_1", "Bertram"),                 # tell Tung
        6: ("sm_asylum_1", "Therese"),              # end the feud
        7: ("la_ventruetower_1", "prince1"),        # report to LaCroix
        8: ("sm_warehouse_1", (112.5, 560.0, -42.7)),  # plant the bomb
    },
    "Hotel": {  # The Ghost Haunts At Midnight
        1: ("sm_oceanhouse_2", "pendant"),          # find the pendant
        2: ("sm_asylum_1", "Therese"),              # give it to Therese
        4: ("sm_asylum_1", "Therese"),              # see Therese later
        5: ("sm_asylum_1", "Therese"),              # see Therese later
    },
    "Slashterpiece": {  # Slashterpiece
        1: ("sm_gallery_1", "painting_0"),          # slash the paintings
        # 3 and 4 (someone else broke in after the player refused) leave nothing to do:
        # the quest ends at Therese's, so they get no marker.
    },
    "Diner": {  # Bad Blood
        1: ("sm_diner_1", "trigger_attack"),        # meet Jeanette at the diner
    },
    "Tourette": {  # Sibling Rivalry
        1: ("sm_asylum_1", "Tourette"),             # go to the Asylum office
        2: ("sm_asylum_1", "Tourette"),             # go to the Asylum office
    },
    "Bloodhunt": {  # Out For Blood
        1: ("sm_hub_2", "Caine"),                   # reach the cab
    },
    "Ming": {  # Ming Must Die!
        1: ("ch_temple_4", "MingXiao2"),            # find Ming-Xiao
        2: ("ch_temple_4", "MingXiao2"),            # kill Ming-Xiao
        3: ("ch_temple_4", "MingXiao2"),            # kill Ming-Xiao
        4: ("ch_temple_4", "MingXiao2"),            # kill Ming-Xiao
        7: ("ch_temple_4", "MingXiao2"),            # kill Ming-Xiao
        8: ("ch_temple_4", "MingXiao2"),            # kill Ming-Xiao
    },
    "Strauss": {  # The Regent's Riddle
        1: ("la_chantry_1", "Regent"),              # find Strauss
    },
    "BertramCD": {  # Missing Data
        1: ("hw_warrens_5", "cd"),                  # find the CD
        2: ("sm_hub_1", "Bertram"),                 # give it to Tung
        4: ("sm_hub_1", "Bertram"),                 # see Tung
    },
    "Heather": {  # Trick Or Treatment
        1: ("sm_medical_1", "Heather"),             # help the dying girl
    },
    "Copper": {  # Daydream Believer
        1: ("sm_pier_1", "Copper"),                 # sell Copper his dream
    },
    "Trip Drugs": {  # Drug Trip
        1: ("sm_medical_1", "prescription_safe"),   # open the drug safe
        2: ("sm_pawnshop_2", "Trip"),               # bring Trip the box
    },
    "Hunter Temple": {  # Temple Cleaning
        1: ("ch_temple_1", "temple_1_h"),           # clear the temple
    },
    "Hunter Hallowbrook": {  # Hotel Service
        1: ("la_bradbury_1", "bradbury_1_h"),       # clear the hotel
    },
    "Hunter Giovanni": {  # Manic Mansion
        1: ("sp_giovanni_1", "giovanni_1_h"),       # clear the mansion
    },
    "Hunter Bloodhunt": {  # Street Festival
        1: ("sm_hub_2", "bloodhunt_2_h"),           # clear the street, exit by the underpass
    },
    "Hunter Society": {  # Home Defense
        1: ("sp_soc_1", "h_beam_terminal"),         # arm the trap
        2: ("sp_tutorial_1", "Hunter1"),            # report to your leader
    },
}
# The main story quest's title, if Santa Monica has one, so the compass can mark it as the main one.
MAIN = ("Mercurio", "Astrolite", "Warehouse", "Hotel", "Diner", "Tourette", "Bloodhunt", "Ming")
