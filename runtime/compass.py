# The quest compass's side in the game's Python (2.1), run in __main__ by bl_compass.c
# after the quest tables (compass_quests_*.py): which quests the player has, at which
# state, and where those states send them. bl_compass.c calls _blc_tick(map) a few times
# a second and reads _blc_out: one line per quest with a place to go,
#   main <tab> map <tab> targetname <tab> "x y z" (where the entity stands now, if this map has it)
# An origin target gives its origin and no name. The native side finds the way there
# when it is on another map.
import __main__

_BLC_QUESTS = {}
_BLC_QUESTS.update(SANTA_MONICA)
_BLC_MAIN = MAIN
_blc_out = ""


def _blc_tick(cur):
    global _blc_out
    out = []
    try:
        pc = __main__.FindPlayer()
    except:
        pc = None
    if pc is None:
        _blc_out = ""
        return
    for title in _BLC_QUESTS.keys():
        try:
            state = pc.GetQuestState(title)
        except:
            continue
        place = _BLC_QUESTS[title].get(state)
        if place is None:
            continue
        name, pos = "", ""
        if type(place[1]) == type(""):
            name = place[1]
            try:
                e = __main__.FindEntityByName(name)
            except:
                e = None
            if e is not None:
                o = e.GetOrigin()
                pos = "%f %f %f" % (o[0], o[1], o[2])
        else:
            pos = "%f %f %f" % place[1]
        main = 0
        if title in _BLC_MAIN:
            main = 1
        out.append("%d\t%s\t%s\t%s" % (main, place[0], name, pos))
    _blc_out = "\n".join(out)
