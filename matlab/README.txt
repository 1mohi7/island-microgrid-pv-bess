AUTO-LOAD OPTIMIZER RESULT PATCH

Copy all .m files in this folder into the root of your MATLAB microgrid folder,
replacing the existing sweep files when prompted.

Normal workflow:
  1. Run runOptimizer.
  2. Make sure its output is saved as results/optimizerResults.mat.
  3. Run any sensitivity sweep normally, e.g. runPvCapexSweep().

No manual basePosition update is needed. If basePosition is omitted, each sweep
loads results.cells.awareAware.sizing from optimizerResults.mat and uses that
as the fixed base design for the regret calculation.

The optional 5th basePosition argument is still supported if you intentionally
want to override the saved optimizer result.

Modified sweeps:
  runPvCapexSweep.m
  runLandCostSweepV2.m
  runTariffSweep.m
  runBatteryCapexSweep.m
  runFuelPriceSweep.m
  runDiscountRateSweep.m
  runExportCapSweep.m

New helper:
  loadBasePositionFromOptimizerResults.m

runLandCostSweep.m is not included because it does not use basePosition/regret.
