# FS25 Assisted Tree Felling - patch notes

## 1.2.6.2

- Updated for the current game version: modDesc descVersion 116 (the game build of 2026-10-27; GIANTS TestRunner 0.9.24 accepts only 116).

## 1.2.6.1
- Meets the GIANTS ModHub checks (TestRunner): textures, icon and modDesc brought up to date.
- Errors are no longer hidden: they show in the log.

## 1.2.6.0 - 2026-11-07 - TEST BUILD
- Centre the crane (zero position) key changed from Left Ctrl + Left Alt + Q to Left Shift + Q.
- Untested.

## 1.2.5.0 - 2026-11-07 - TEST BUILD
- New Ctrl+Q zero position on the H21D 706: head low, arm out in front (lift 4.29, reach -37.29, was 11.84 / -50), from the user's server save.
- Q now cuts as soon as the ring is green and the bottom of the head is within 2 cm of the ground, whatever the aim is doing. On the server, Q aimed the head onto the ground at the tree but never cut (the aim stopped as "stuck").
- The gap is measured on the head itself (short rays up from the ground under the head), not from the saw.
- Untested.

## 1.2.3.0 - 2026-11-06 - TEST BUILD
- 1.2.2.0 final test: 4 trees felled and lifted (2.22-2.25 m, lift 2.2-2.6 s after the cut); one stuck aim correctly did not cut. One lift stopped part way: machine tilted 4 degrees more while lifting (2.2 -> 6.2).
- Test run removed (Left Ctrl + Left Shift + Q and scripts/ATFTest.lua). The script is kept in the project's dev folder, not in the mod.
- Fix: after a Q felling, aiming could stay blocked (the test and O did nothing) because the game hides the Q action once the tree is cut, so the mod never saw Q being let go. Q now counts as let go after 0.3 s without Q input.
- Untested.

## 1.2.2.0 - 2026-11-06 - TEST BUILD: keeps lowering
- 1.2.1.0 in game: Q refused to cut every time ("not cutting"), because the game's own aim said "done" as soon as the reach was close enough, which also stopped the lowering with the head still up. That is probably also what cut the high tree in 1.2.0.0.
- Now when the game's aim says "done" by itself, the mod keeps lowering until the head is on the ground, then cuts and lifts.
- Lift after the cut is now full speed (was half speed). Aiming stays at half speed.
- Untested.

## 1.2.1.0 - 2026-11-06 - TEST BUILD: no more high cuts
- 1.2.0.0 in game: trees 1-3 went aim -> ground -> cut -> lift (saw 2.58-2.66 m) fine, but one tree was cut about 1 m up: the aim had stopped early (head stuck) while the tree was already green, and Q cut anyway.
- Q now only cuts when the aim stopped because the head is on the ground (or at the cut height). Any other stop (stuck, no progress, out of reach, tilt): no cut, and an on-screen message says so; let go of Q and try again, or cut with X.
- The log now says why each aim stopped.
- Lift after the cut lowered from 2.6 m to 2.25 m (saw above the ground).
- Untested.

## 1.2.0.0 - 2026-11-06 - TEST BUILD: Q fells the tree
- Holding Q on 1.1.0.4: the head went down to the ground at the tree and stopped there cleanly (tilt rose only about 1 degree).
- New: holding **Q** now also **cuts the tree** once the head is on it at the ground, and straight after the cut **lifts it** until the saw is about 2.6 m above the ground (the top line in the user's photo), then holds it so you can back out. Let go of Q to stop at any time.
- **O** (the game's own key) still only aims, so you can cut with X yourself.
- Lifting stops if the machine tilts more than 4 degrees.
- Test key (Left Ctrl + Left Shift + Q) while holding a tree: shows the saw's height above the ground on screen (to set the lift height exactly).
- Untested.

## 1.1.0.4 - 2026-11-06 - TEST BUILD
- 1.1.0.3 test run: both trees in front of the machine went green with the saw 0.23-0.24 m above the ground; the head then touched the ground and the tilt guard stopped it at about 6 degrees. Centring spot on.
- Test run now shows on-screen messages in the game (start, each tree's result, tilt stop, and "FINISHED, you can move the machine").
- Second 1.1.0.3 run: a 7.5 m tree was out of reach of the main arm (it sat at its end stop pushing for 10 s; the telescope never moved), the head swayed so the stuck rule didn't fire, then dropped and the machine went to 20 degrees.
- Telescope now pushes out when the main arm is at its end stop and the head is still short of the tree.
- Stops when the tree is out of reach (arm and telescope both at their limits), and when the head gets no closer to the trunk for 3 seconds.
- Tilt guard: the starting tilt can only go down during an aim (it had taken 6.3 degrees while the machine was still rocking), plus a hard stop above 8 degrees.
- Test run waits for the machine to stop rocking before aiming at the next tree.
- Holding Q on 1.1.0.3: head on the tree, green, stopped by itself - good. Stump still too tall.
- Cut height is now the ground: the head lowers until it touches the ground at the tree, and stops there the moment the machine tilts 1 degree (with the tree green). That is the lowest stump the head can give. Then tap X to cut.
- Test run stops (with an on-screen message) if the head is holding a tree. In 1.1.0.3 the player cut a tree mid-test (one tap of X after the aim: clean cut) and the test then aimed the next tree with the felled tree still in the head, which tipped the machine.
- Untested.

## 1.1.0.3 - 2026-11-06 - TEST BUILD
- Test runs in 1.1.0.2: the swing now lines up well, but (1) for trees far to the side the crane pulled the arm back to its stop and never swung, and (2) the head was lowered to cut height while still ~2 m short of the tree, hit the ground, and the crane kept pushing down until the machine tilted 20 degrees.
- Pull-back step: if the arm hits its end stop, it moves on to the swing.
- Comes in high, drops at the tree: while the head is more than 60 cm from the trunk it stays about 80 cm above the ground, then drops to the cut height at the tree.
- Tilt guard (normal use too, not only the test): if the machine tilts more than 4 degrees from where it was when the aim started, the aim stops at once.
- Untested.

## 1.1.0.2 - 2026-11-06 - TEST BUILD
- Test run found 0 trees in 1.1.0.1. The tree scan now also uses the trees the game's own auto-aim finds, and logs how many each scan found.
- In 1.1.0.1's test the crane didn't move at all while the aim was in its pull-back step (tree 71 degrees to the side, 25 s timeout). The stuck rule (stop after 1.5 s without 2 cm of movement) now covers the pull-back step too.
- The test log now also shows what the aim tells each joint to do, and where each joint is.
- Test runs in 1.1.0.1 (4 trees): a tree at 19 degrees made the head sway side to side and the machine rock until it tilted 20 degrees (test stopped it). Cause: the swing aimed with the hanging head, so it chased the sway. The swing now aims with the crane tip above the head's joint (like the game does).
- Green-ring stop now also waits until the head is down at the cut height (one test stopped green with the saw 0.79 m up).
- Centring only counts as done when every joint is really there (one test ended with the swing 10.7 degrees off).
- Centre crane key changed to **Left Ctrl + Left Alt + Q** (Left Ctrl + Q didn't work; it's the game's Detach key).
- Untested.

## 1.1.0.1 - 2026-11-06 - TEST BUILD (in-game test run)
- Everything in 1.1.0.0, plus a test run: **Left Ctrl + Left Shift + Q** in the Rottne (single player / host). It aims at up to 8 reachable trees in turn (never cuts), writes where the saw ends up to log.txt (lines start with [ATF-TEST]), centres the crane after each one, and stops if the machine tilts more than 20 degrees. Press again to stop.
- The test run (scripts/ATFTest.lua, the ATF_TEST key) comes out again before a normal release.
- Ctrl+Q on the Rottne H21D 706 now goes to your own position (taken from your save): swing 0, lift 11.8 deg, main arm -50 deg, telescope fully in, head turn 0. The other Rottne versions still go to their start position.

## 1.1.0.0 - 2026-11-06 - Centre the crane (Left Ctrl + Q)
- New: press **Left Ctrl + Q** once to centre the crane. It first pulls the telescope in and puts the arms and head back to their start position (as when unfolded), then swings the crane and cab back to straight ahead. Full speed (auto-aim stays at half speed).
- Stops by itself when it's back (or after 30 seconds). Pressing Q to aim cancels it.
- Left Ctrl + Q is also the game's Detach key; nothing attaches to the Rottne, so it doesn't clash there.
- Includes everything from 1.0.3.0 (crane stops on green ring or when stuck), which was never sent out.
- Untested.

## 1.0.3.0 - 2026-11-06 - Crane stops by itself
- In 1.0.2.0, holding Q too long kept the crane pushing after the head reached the tree, and it could tip the machine over.
- The crane now stops as soon as the head is in cutting position on the aimed tree (green ring), and also stops if the head gets stuck (moves less than 2 cm in 1.5 seconds).
- After it stops, holding Q longer does nothing. Let go and press again to aim again.
- Swing, reach, height (15 cm) and half speed are unchanged.
- Untested.

## 1.0.2.0 - 2026-11-06 - Head lands on the tree, not beside it
- In 1.0.1.0 the crane sometimes stopped with the head about half a metre beside the trunk (yellow ring).
- The swing now lines up the head itself with the tree, seen from above, using where the head really is. The game's own swing maths doesn't fit the Rottne's crane joint.
- Reach, height (15 cm) and half speed are unchanged.
- Untested.

## 1.0.1.0 - 2026-11-06 - Head not so low
- In 1.0.0.0 the head went too low at the tree. Cut height raised from 10 cm to 15 cm above the ground (measured at the saw), on all 4 Rottne versions.
- Auto-aim moves the crane at half speed (swing, reach, lift, telescope and head turn), so the head no longer slams down. Moving the crane yourself is full speed as before.
- Untested.

## 1.0.0.0 - 2026-11-06 - First build
- Rottne H21D (all 4 versions in the Rottne Pack): the game's crane auto-aim is switched on. 706 versions use the base-game John Deere 1270G settings unchanged; 7000C versions use the same John Deere settings with the Logmax head's two joint names (the Rottne Pack author's switched-off block).
- A ring shows on the tree you can fell: yellow = in reach, green = head on the tree, red = too thick / not allowed.
- Hold **Q**: the crane swings to the tree, reaches in and sets the head at cut height, exactly like the game's own auto-aim key **O** (which also works now). You cut with the normal cut key. Let go of Q to stop.
- Trees are picked up 4.5-8 m from the crane (John Deere settings).
- Cut height: the head goes as low as the game allows, about 10 cm above the ground at the tree (John Deere: 50 cm).
- The Rottne Pack's files are not changed. No other machines are changed.
- Untested.
