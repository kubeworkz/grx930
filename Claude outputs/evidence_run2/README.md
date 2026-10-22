# run2 (pad-mask-skipped precheck) — measured evidence, collected 2026-10-16

container: ws-precheck2, ghcr.io/wafer-space/gf180mcu-precheck, exited (0) after the run
input:     /home/kubew/submit/run1/chip_top.gds  sha256 764c79babda6299b8ce9a7bf86662ca0c4459c6b404ffab4783e94840e068605
           (byte-identical to the shipped template GDS chip_top_template.gds, 160,256,792 B)
precheck:  --slot 1x1 --cob --id GRX93001, top_cell chip_top, 4 threads / 4 workers
start:     2026-10-15 23:38:15 UTC      end: 2026-10-16 11:12:25 UTC (11 h 34 m)

density      FAIL (deferred)  2 violations: DCF.1b (COMP+dummy COMP >= 25%), PL.8 (Poly2 = 14%)
zero-area    pass             0 on every layer  (klayout__zero_area_polygons__count 0)
antenna      pass             0 on every ANT.* rule (klayout__antenna_error__count 0)
Magic DRC    12,772 errors     warning level, not deferred, not a gate
KLayout DRC  FAIL (deferred)  83,777 violations over 737 rules; 71,575 (85.4%) are *_OFFGRID
LVS          no such stage in the precheck at all

Final exception text: One or more deferred errors were encountered:
  2 KLayout density errors found. / 83777 KLayout DRC errors found.
The container exits 0 on failure — the verdict lives only in precheck_ws.log.

Files here:
  density.klayout.{json,lyrdb}    density check, 2 items, rule text in the lyrdb
  zeroarea.klayout.json           zero-area-polygon counts, all 0
  antenna.klayout.json            per-rule antenna counts, all 0
  klayout_drc.klayout.json        per-rule DRC tally (736 rules + total 83777)
  flow.log                        the flow's own step-by-step record
  gds_grid_scan.py                scanner used for the off-grid finding (python3, stdlib only)

Off-grid measurement (scanner output):
  artifact            9,312,368 coordinate pairs, 6,020,091 off the 5 nm grid (64.65%)
  cell sealring$1     4,370,396 of those coordinates
  ID-stamped GDS      6,019,936 off-grid (155 fewer = the ID polygons; the ID step is not the cause)
