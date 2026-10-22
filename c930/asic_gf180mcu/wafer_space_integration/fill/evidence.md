# Active-layer fill: measured evidence

Extracted from the flow box's /home/kubew/fillrun*.log. Every number in ../fill/README.md
and in the KLAYOUT_FILLER_* block of grx930_overrides.yaml is one of the lines below.
The deck is the gf180mcuD one from the pinned pre-check image
(ghcr.io/wafer-space/gf180mcu-precheck), run the way the pre-check runs it:
`-rd variant=gf180mcuD -rd run_mode=deep`, `-rd threads=6`, one `-rd decks=` list per line.

## The flow's own artifact today: submit/run1/chip_top.gds = tpl02/92-klayout-filler

```
# layer areas (check_active_density.rb: merged; the deck's raw-mode COMP reads 20.182 %)
=== Fri Oct 16 20:07:45 UTC 2026 CHECKER on the flow's own foundry fill (submit/run1/chip_top.gds)
die bbox                 : 3932.0 x 5122.0 um = 20139704 um^2
COMP          22/0        : 16.838 % of die
COMP dummy    22/4        :  3.036 % of die
Poly2         30/0        :  9.240 % of die
Poly2 dummy   30/4        :  3.411 % of die
------------------------------------------------------------
DCF.1b   [25.0..70.0] : 19.874 %  FAIL
DCF.1d   [0.0..70.0]  : 19.874 %  PASS
PL.8     [>= 14.0]    : 12.651 %  FAIL
CHK_BASE_EXIT:1
# the deck's own verdict on it (decks=dummy_comp,density)
2026-10-16 19:48:02 +0000: Memory Usage (1206708K) : Poly2 ratio: 12.992005364547563 %
2026-10-16 19:59:24 +0000: Memory Usage (1093380K) : DRC RESULT: FAILURE (2 violation(s))
2026-10-16 19:59:24 +0000: Memory Usage (1093512K) :   'DCF.1b'             :     1 violation(s)
2026-10-16 19:59:24 +0000: Memory Usage (1093512K) :   'PL.8'               :     1 violation(s)
```

## The PDK pattern with the 10 um COMP halo removed (fillrun/flow_base.log)

```
COMP exclusion halo: 0.0 um
Starting Poly2 fill…
Pairing dummy Poly2 with dummy COMP…
  dummy COMP      :      2396225 um^2
  dummy Poly2     :       690171 um^2 (22008 squares)
  dropped by DPF  :   77.0 % of the paired squares
COMP        22/0         : 16.838 % of die
Poly2       30/0         :  9.240 % of die
Poly2 dummy 30/4         :  3.427 % of die
DCF.1b   [25.0..70.0] : 28.736 %  PASS
DCF.1d   [0.0..70.0]  : 28.736 %  PASS
PL.8     [>= 14.0]    : 12.667 %  FAIL
```

## 6.0 on 1.9 with the foundry's 1.6 stagger (fillrun/dense.log)

```
Pairing dummy Poly2 with dummy COMP…
  dummy COMP      :      3070548 um^2
  dummy Poly2     :       764742 um^2 (2617 squares)
  dropped by DPF  :   80.1 % of the paired squares
COMP dummy  22/4         : 15.246 % of die
Poly2 dummy 30/4         :  3.797 % of die
DCF.1b   [25.0..70.0] : 32.084 %  PASS
DCF.1d   [0.0..70.0]  : 32.084 %  PASS
PL.8     [>= 14.0]    : 13.037 %  FAIL
```

## The per-exclusion cost of the ten-distance policy (fillrun/zone.log)

```
die            :     20139704 um^2
dummy COMP     :      3070548 um^2  (15.246 % of die)
paired (cmp+0.3):     3713442 um^2  (18.438 % of die)

per-exclusion cost (whole paired squares dropped):
  Poly2      5.0 um :        14493 um^2  (0.072 % of die)
  RES_MK    19.7 um :       103832 um^2  (0.516 % of die)
  NDMY      29.7 um :        17521 um^2  (0.087 % of die)
  PMNDMY     8.0 um :        41651 um^2  (0.207 % of die)
  MTPMK      3.0 um :            0 um^2  (0.000 % of die)
  Pad        6.7 um :         3088 um^2  (0.015 % of die)
  Metal1     2.0 um :      2747852 um^2  (13.644 % of die)
  Metal2     2.0 um :       903320 um^2  (4.485 % of die)
  IND_MK     3.0 um :            0 um^2  (0.000 % of die)
  Nwell      1.0 um :            0 um^2  (0.000 % of die)
  DNWELL     2.0 um :            0 um^2  (0.000 % of die)
  LVPWELL    1.0 um :            0 um^2  (0.000 % of die)
  Dualgate   1.0 um :            0 um^2  (0.000 % of die)
  scribe    26.0 um :        26871 um^2  (0.133 % of die)

kept pairs     :       764742 um^2  (3.797 % of die)
Poly2 drawn    :      1860838 um^2  (9.240 % of die)
EXIT=0
```

## 6.0 on 1.9 with 1.6 stagger, pair_metal_um 0 -- density passes, but ILLEGAL (fillrun3.log)

```
  pattern: COMP_fill_cell = 6.0 x 6.0 um on 1.9 um
Pairing dummy Poly2 with dummy COMP…
  DPF.12/DPF.13 metal halo: 0.0 um (off: the gf180mcuD deck comments both rules out)
  dummy COMP      :      3070548 um^2
  dummy Poly2     :      3527856 um^2 (63322 squares)
  dropped by DPF  :    5.0 % of the paired squares
FILL_EXIT:0
COMP        22/0         : 16.838 % of die
COMP dummy  22/4         : 15.246 % of die
Poly2 dummy 30/4         : 17.517 % of die
DCF.1b   [25.0..70.0] : 32.084 %  PASS
DCF.1d   [0.0..70.0]  : 32.084 %  PASS
PL.8     [>= 14.0]    : 26.757 %  PASS
Executing rule DCF.1b
COMP ratio: 33.44877868597274 %
Executing rule DCF.1d
Executing rule PL.8
Poly2 ratio: 26.756569381973037 %
DRC RESULT: FAILURE (46017 violation(s))
  'DCF.2b'             : 42688 violation(s)
  'DF.11'              :    16 violation(s)
  'DF.13_MV'           :   257 violation(s)
  'DF.16_MV'           :   320 violation(s)
  'DF.17_MV'           :    66 violation(s)
  'DF.1a_MV'           :    16 violation(s)
  'DF.2a_MV'           :   249 violation(s)
  'DF.3a_MV'           :   185 violation(s)
  'DF.3b'              :   396 violation(s)
  'DF.4c_MV'           :   333 violation(s)
  'DF.4d_MV'           :   199 violation(s)
  'DF.6_MV'            :   272 violation(s)
  'PL.1_MV'            :     2 violation(s)
  'PL.2_MV'            :   142 violation(s)
  'PL.3a'              :    80 violation(s)
  'PL.4_MV'            :   157 violation(s)
  'PL.5a_MV'           :   195 violation(s)
  'PL.5b_MV'           :   195 violation(s)
  'PL.6'               :   249 violation(s)
DECK_EXIT:0
```

## The shipped pattern: 6.0 / 2.0 / stagger 0.5 (fillrun4.log)

```
  pattern: COMP_fill_cell = 6.0 x 6.0 um, stagger 0.5 um, minimum dummy COMP space 2.000 um (DCF.2b wants 1.9)
Pairing dummy Poly2 with dummy COMP…
  DPF.12/DPF.13 metal halo: 0.0 um (off: the gf180mcuD deck comments both rules out)
  dummy COMP      :      2884464 um^2
  dummy Poly2     :      3426647 um^2 (78665 squares)
  dropped by DPF  :    1.8 % of the paired squares
FILL_EXIT:0
COMP          22/0        : 16.838 % of die
COMP dummy    22/4        : 14.322 % of die
Poly2 dummy   30/4        : 17.014 % of die
DCF.1b   [25.0..70.0] : 31.160 %  PASS
DCF.1d   [0.0..70.0]  : 31.160 %  PASS
PL.8     [>= 14.0]    : 26.254 %  PASS
COMP ratio: 31.273910574703578 %
Poly2 ratio: 26.25403801408402 %
DRC RESULT: SUCCESS (0 violations)
DECK_NEW_EXIT:0
COMP ratio: 20.182089165610375 %
Poly2 ratio: 12.992005364547563 %
DRC RESULT: FAILURE (2 violation(s))
  'DCF.1b'             :     1 violation(s)
  'PL.8'               :     1 violation(s)
DECK_BASE_EXIT:0
```

## The shipped pattern against the fill's own two decks (fillrun6.log)

```
=== Fri Oct 16 20:07:45 UTC 2026 DECK dummy_comp+dummy_poly2 on the new fill
DRC RESULT: SUCCESS (0 violations)
DECK_PAIR_EXIT:0
```

## The base comp/poly2 decks on the UNFILLED pre-fill GDS (fillrun5.log)

Same rule list as the filled die shows, so the dummy fill adds none of it:

```
DRC RESULT: FAILURE (3329 violation(s))
  'DF.11'              :    16 violation(s)
  'DF.13_MV'           :   257 violation(s)
  'DF.16_MV'           :   320 violation(s)
  'DF.17_MV'           :    66 violation(s)
  'DF.1a_MV'           :    16 violation(s)
  'DF.2a_MV'           :   249 violation(s)
  'DF.3a_MV'           :   185 violation(s)
  'DF.3b'              :   396 violation(s)
  'DF.4c_MV'           :   333 violation(s)
  'DF.4d_MV'           :   199 violation(s)
  'DF.6_MV'            :   272 violation(s)
  'PL.1_MV'            :     2 violation(s)
  'PL.2_MV'            :   142 violation(s)
  'PL.3a'              :    80 violation(s)
  'PL.4_MV'            :   157 violation(s)
  'PL.5a_MV'           :   195 violation(s)
  'PL.5b_MV'           :   195 violation(s)
  'PL.6'               :   249 violation(s)
DRC RESULT: FAILURE (3329 violation(s))
```

## The two diagnostics on the shipped fill (fillrun7.log)

This run predates the "policy:" banner line zone_capacity.rb now prints; the exclusion set
and the arithmetic are unchanged.

```
dummy COMP            :      2884464 um^2  (14.322 % of die)
Poly2 pairing zone    :      1619604 um^2  ( 8.042 % of die)
  dummy COMP in it    :       767174 um^2  ( 3.809 % of die)
  free, 1.9 clear     :       206009 um^2  ( 1.023 % of die)
Poly2 drawn           :      1860838 um^2  ( 9.240 % of die)
  paired Poly2        :       929861 um^2  ( 4.617 % of die)
  cell   3.0 um (42 % coverage): +  86437 um^2 COMP, + 124470 um^2 Poly2 -> PL.8 14.475 %
  cell   6.0 um (60 % coverage): + 123915 um^2 COMP, + 149937 um^2 Poly2 -> PL.8 14.601 %
  cell  12.0 um (76 % coverage): + 155601 um^2 COMP, + 171550 um^2 Poly2 -> PL.8 14.708 %
  cell  20.0 um (84 % coverage): + 172735 um^2 COMP, + 183255 um^2 Poly2 -> PL.8 14.767 %
ZONECAP_EXIT:0
dummy COMP     :      2884464 um^2  (14.322 % of die)
kept pairs     :       899296 um^2  (4.465 % of die)
Poly2 drawn    :      1860838 um^2  (9.240 % of die)
ZONE_EXIT:0
```
