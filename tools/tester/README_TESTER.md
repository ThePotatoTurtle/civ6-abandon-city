# Abandon Cities spike test: tester guide

Thanks for helping out. This is a short test of a Civ VI mod idea. You will click a few buttons in a test panel, look at what the game does, and send the results back. It takes about 20 minutes, plus an optional 3.

Nothing here changes your real games. Just never turn the test mod on in a game you care about.

## What you need

- Windows PC with Civilization VI and the Gathering Storm expansion
- The test must be done in NEW games only. Never load an old save with the test mod on.
- For the hotseat part you only need this one PC. You play all the seats yourself.

## Install

1. Unzip the whole package to a normal folder (for example your Desktop). Do not run things from inside the zip.
2. Quit Civilization VI completely (to the desktop).
3. Double-click **INSTALL.bat**. It asks where your Civ VI folders are. It guesses them for you, so just press Enter if the path looks right (it might be inside OneDrive, that is fine). If it is wrong, type or paste the right path.
   - Mods folder: usually `...\Documents\My Games\Sid Meier's Civilization VI\Mods`
   - Logs folder: usually `C:\Users\<you>\AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs`
   - If Windows shows a blue "protected your PC" box, click More info, then Run anyway.
4. Start the game and open **Additional Content** from the main menu.
   - Enable **Abandon Cities Spike Tools (testing only) v0.0.0.1** and **Gathering Storm**.
   - Disable **every other mod** you have (Cheat Menu Panel, Simple UI Adjustments, anything else). The test needs a clean setup.
   - The test panel uses the Ctrl+Shift+D key. Any other mod that also uses that key must be off.
5. In a game, open the test panel with **Ctrl+Shift+D**, or click the **DEV** button on the top left launch bar.
   - The panel shows the test cities and the latest result lines, so keep it open while you test.
   - Before each risky step the panel prints an "about to run Gn" line. If the game freezes or crashes, the last line on screen tells us which call did it. Take a photo of the screen before restarting.

To remove the mod afterwards, double-click **UNINSTALL.bat**.

## If the game crashes during step 11 (S1 Run)

Restart the game, start a new game, found the capital, and click **S0 Setup**. Then click **S1 One** once per variant: G1 first, then G2, then G3 (one click each, restarting if it crashes again). The "about to run Gn" line tells us which call crashed. Then carry on with step 12.

## Screenshots

Steam: press **F12** in the game (find them in Steam under View, Screenshots). Or use **Win + Shift + S** and save the picture. Take a screenshot wherever the steps below say so, and whenever something looks odd.

## Part 1: single player (about 14 min)

Start a new game: Pangaea, Standard size, 3 AI, Prince, barbarians on.

For every step, write what you saw on the **Result:** line (works / does not work / something different, plus any numbers you saw). Short notes are fine.

1. Found the capital, press Ctrl+Shift+D, click **S0 Setup**.
   Why: makes the test cities for every later step.
   Expect: the panel lists 7 cities (S3-C, S3-A, S3-B0, S3-B1, S3-B2, S2, S4) with x,y; CHECK S0_CITIES PASS and S0_CAMPUS PASS; Campus districts visible next to S3-A, S3-B0, S3-B1 and S3-B2. A wonder line for S3-A (ok=false means "wonder effect deferred").
   Result:
2. Click **P Probes**.
   Why: capital / original-capital / war checks for the blocking rules.
   Expect: gameplay lines P own_capital / S2 / ai_capital and the matching "P UI" lines show the same values (capital true/false/true, original capital true/false/true, original owner = owner); CHECK P_WAR63 PASS.
   Result:
3. Click **S2a To 8**, open city S2, look at the citizens and the growth bar. Click **S2b Cut**, reopen S2.
   Why: population cut call.
   Expect: CHECK S2_POP8, S2_POP6 and S2_POP2 PASS (8, then 6 and 2); worked tiles drop to match; the S2 lines say what happened to the food store.
   Result:
4. Click **S3 Step** (1st). Open S3-B1 and S3-B2, take a screenshot of the loyalty breakdown, look at the banner arrows.
   Why: does the loyalty debuff show in the forecast?
   Expect: a -6 line ("Other effects") on B0, B1 and B2; banner per-turn 6 lower; the "S3 UI" lines list the breakdown entries. CHECK S3_P1 PASS if gameplay can read loyalty (else only UI lines).
   Result:
5. Click **S4 Run**. Attack the adjacent enemy warrior with your new warrior. Click **S4 Read**.
   Why: siege, damage and the 6-tile enemy scan.
   Expect: S4 surrounded by enemy warriors, garrison damage 40 readable; "S4 UI ... UI IsUnderSiege=true"; CHECK S4_SCAN PASS (the 6-tile barbarian is listed, the 7-tile one is not); an "S4 combat" line after your attack.
   Result:
6. Click **S6 Attach**. Open your capital: check the new S6 button, click it, change production, use prev/next city, close the city panel.
   Why: least invasive button spot.
   Expect: an aligned 44x53 button after the gold/faith/production buttons that keeps working (each click adds an "S6 ... button click" UI line) and hides with the panel.
   Result:
7. Click **S5 Self**. Check the notification rail, click the one with a location.
   Why: custom notification types.
   Expect: two custom notifications with the spike text and icons (A: city lost icon, B: generic icon); clicking A centres on S4.
   Result:
8. End the turn.
   Why: turn-start readings (loyalty, siege after heal, regrowth, turn-start notification).
   Expect: a new notification A at turn start; notification A from last turn gone, B still there; S3-A loyalty 6 lower; a "P turn ... arg=N Game.GetCurrentGameTurn()=N" line.
   Result:
9. Click **S3 Step** (2nd). Reopen S3-B1 and S3-B2. End the turn.
   Why: can the debuff be switched off and re-levelled?
   Expect: B1 back to normal, B2 at -9; CHECK S3_P2 PASS if gameplay can read loyalty.
   Result:
10. Click **S3 Step** (3rd). End the turn.
    Why: switch-off of the data-only variant.
    Expect: B2 back to normal; B0 still -6; CHECK S3_P3 PASS if gameplay can read loyalty.
    Result:
11. Click **S1 Run**. Read the panel; watch the end-turn button and the units. Click **S1 Check**.
    Why: which city-removal call works, and what it does.
    Expect: "S1 UI" lines with the CityDestroyDirectives values and CanStartCommand results; CHECK S1_G1 / S1_G2 / S1_G3 say which call removed its city; some test cities gone, no error, no "consider razing" blocker; the "S1 after" line says where the units went.
    Result:
12. Click **S1 Arm T**, end the turn, click **S1 Check**.
    Why: removal from the real turn hook.
    Expect: S2 removed at turn start (CHECK S1_G<n>_TURNSTART PASS), or "none" if no G variant worked.
    Result:
13. Quit to the desktop (the full desktop, not just the main menu). Then double-click **COLLECT_LOGS.bat**.
    Why: the game only finishes writing its log when you quit, and this grabs the log files for us.
    Expect: a zip called ABN_SpikeLogs_<date>.zip appears on your Desktop, and the game log has no "Runtime Error" lines.
    Result:

## Part 2: hotseat (about 5 min)

You only need this one PC; you play all the seats yourself. Start the game again after step 13 if you quit.

14. Hotseat: new game (Large map; P0 you, P1 and P2 human, 1 AI). Same mods. As P0, after founding the capital: **S5 HS Setup**, **S5 HS Send**, **S1 HS Arm**. End turns through P1 and P2 and back to P0.
    Why: met-only notifications and the hotseat guard.
    Expect: P1 gets notifications A and B (and a new A at turn start) and P2 gets none; the panel's "S1 ... HS skip" lines on P1 and P2, and the RAZE command (or "RAZE not allowed") only on P0's turn.
    Result:

## Part 3: optional (about 3 min)

If you have the mod "Simple UI Adjustments", this checks that the two mods get along. Skip it otherwise.

15. Enable Simple UI Adjustments (leave everything else off). New single player game, found the capital, repeat step 6.
    Why: compatibility.
    Expect: same as step 6.
    Result:
16. Quit to the desktop and double-click **COLLECT_LOGS.bat** again.
    Why: hotseat and Part 3 numbers.
    Expect: no errors.
    Result:

Two-machine online multiplayer is not part of this test; just write "not tested" for it.

## Sending it back

Send these to Leon:

- the zip(s) from COLLECT_LOGS.bat (they appear on your Desktop)
- your screenshots
- this file with the **Result:** lines filled in (or just copy the lines into a message)

## If something goes wrong

- The BAT file says the game is running: quit Civ VI fully and try again. Check Task Manager if needed.
- Wrong folder paths: run the BAT again and answer "n" at the "Use these?" question, or delete `install_tester.config.json` and start over.
- Nothing appears in Additional Content: the Mods path was probably wrong. Run INSTALL.bat again with the correct Mods folder.
- Any other trouble: take a screenshot and send it with a short note about what you clicked.
