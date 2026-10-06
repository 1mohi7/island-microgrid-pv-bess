function grid = gridConnectionModel(P)
%GRIDCONNECTIONMODEL  Import, export, settlement and emissions at the boundary.
%
%   grid = gridConnectionModel(P)
%
%   NET METERING SETTLEMENT follows Net Metering Guidelines 2025. Within a
%   billing period, exported units net against imported units at the RETAIL
%   rate; only a net export surviving to the end of a QUARTERLY settlement
%   period is paid out, and then at the BULK rate of 8.39 BDT/kWh.
%
%   On this feeder that distinction turns out to be academic: import exceeds
%   export in every quarter by a wide margin, so export always settles at
%   retail and the bulk rate never applies. That makes the export credit rate
%   far less influential than the brief anticipated. It is a reportable result,
%   not a modelling shortcut, and the code implements the full rule anyway so
%   that a larger array or a different tariff would settle correctly.

grid.exportPowerCapKilowatts = P.tariff.exportPowerCapKilowatts;

grid.importCostBdt = @(kilowattHours) ...
    kilowattHours * P.tariff.importTariffBdtPerKilowattHour;

grid.exportCreditBdt = @(kilowattHours) ...
    kilowattHours * P.tariff.exportCreditBdtPerKilowattHour;

grid.carbonDioxideKilograms = @(importedKilowattHours) ...
    importedKilowattHours * P.tariff.carbonDioxideEmissionFactorKgPerKilowattHour;

grid.settleNetMetering = @(quarterlyImport, quarterlyExport) ...
    settleQuarterly(quarterlyImport, quarterlyExport, P);

end

% =====================================================================
function [energyCostUsd, exportPayoutUsd] = settleQuarterly(quarterlyImport, ...
                                                            quarterlyExport, P)
energyCostBdt   = 0;
exportPayoutBdt = 0;
for quarter = 1:numel(quarterlyImport)
    offset         = min(quarterlyExport(quarter), quarterlyImport(quarter));
    billableImport = quarterlyImport(quarter) - offset;
    surplusExport  = quarterlyExport(quarter) - offset;
    energyCostBdt   = energyCostBdt   + billableImport * P.tariff.importTariffBdtPerKilowattHour;
    exportPayoutBdt = exportPayoutBdt + surplusExport  * P.tariff.exportCreditBdtPerKilowattHour;
end
energyCostUsd   = energyCostBdt   / P.costs.bangladeshiTakaPerUnitedStatesDollar;
exportPayoutUsd = exportPayoutBdt / P.costs.bangladeshiTakaPerUnitedStatesDollar;
end
