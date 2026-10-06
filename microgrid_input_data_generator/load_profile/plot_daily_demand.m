function dailyDemandTable = plot_daily_demand(hourlyLoad, modelInfo, varargin)
%PLOT_DAILY_DEMAND  Average daily demand, per month and across the full year.
%
%   dailyDemandTable = plot_daily_demand(hourlyLoad, modelInfo)
%   dailyDemandTable = plot_daily_demand(hourlyLoad, modelInfo, 'Name', Value)
%
%   Called automatically by substation_load_profile when
%   config.output.showDailyPlots is true, so it normally needs no direct call.
%
%   Produces:
%     Figure 1 - one panel per month (January ... December), x = day of
%                month, y = average demand on that day.
%     Figure 2 - every day of the year on one axis, x labelled with month
%                names at the month boundaries.
%
%   INPUTS
%     hourlyLoad : hourly demand vector from substation_load_profile
%     modelInfo  : the struct from the same call (supplies calendar + units)
%
%   OPTIONS
%     'Layout'    'grid' (default) puts all months in one 3x4 figure;
%                 'separate' opens one figure per month.
%     'SameYLim'  true (default) gives every month panel the same y range so
%                 months are directly comparable. false autoscales each.
%     'ShowMean'  true (default) draws a dashed line at the monthly mean.
%     'SaveDir'   directory for PNG output. '' (default) saves nothing.
%     'SaveCSV'   true writes daily_mean_demand.csv into SaveDir.
%
%   OUTPUT
%     dailyDemandTable : date, year, month, day, month name, mean demand.

% ------------------------------------------------------------------------
% 0. Options
% ------------------------------------------------------------------------
optionParser = inputParser;
addParameter(optionParser, 'Layout',  'grid', ...
    @(value) any(strcmpi(value,{'grid','separate'})));
addParameter(optionParser, 'SameYLim', true,  @islogical);
addParameter(optionParser, 'ShowMean', true,  @islogical);
addParameter(optionParser, 'SaveDir',  '',    @ischar);
addParameter(optionParser, 'SaveCSV',  false, @islogical);
parse(optionParser, varargin{:});
options = optionParser.Results;

if nargin < 2
    error(['plot_daily_demand needs two inputs. Run the model first:\n' ...
           '   [hourlyLoad, monthlyStatsTable, modelInfo] = substation_load_profile();\n' ...
           '   plot_daily_demand(hourlyLoad, modelInfo);\n' ...
           'Pressing Run in the editor calls this file with no arguments, ' ...
           'which is what produces this error.']);
end
if ~isstruct(modelInfo) || ~isfield(modelInfo,'calendarData')
    error('modelInfo must be the struct returned by substation_load_profile.');
end

calendarData  = modelInfo.calendarData;
unitLabel     = modelInfo.config.site.units;
siteName      = modelInfo.config.site.name;
numberOfDays  = calendarData.numberOfDays;

if numel(hourlyLoad) ~= 24*numberOfDays
    error(['hourlyLoad has %d elements but the calendar covers %d days ' ...
           '(%d hours expected).'], numel(hourlyLoad), numberOfDays, 24*numberOfDays);
end

saveDirectory = options.SaveDir;
if ~isempty(saveDirectory) && exist(saveDirectory,'dir') ~= 7
    mkdir(saveDirectory);
end

% ------------------------------------------------------------------------
% 1. Daily means
% ------------------------------------------------------------------------
dailyMeanDemand = mean(reshape(hourlyLoad, 24, numberOfDays), 1)';

monthNameList = {'January','February','March','April','May','June', ...
                 'July','August','September','October','November','December'};

dailyDemandTable = table(calendarData.dateNumber, calendarData.yearOfDay, ...
    calendarData.monthOfDay, calendarData.dayOfMonth, ...
    monthNameList(calendarData.monthOfDay)', dailyMeanDemand, ...
    'VariableNames', {'dateNumber','year','month','dayOfMonth', ...
                      'monthName', ['meanDemand_' unitLabel]});

if options.SaveCSV
    csvDirectory = saveDirectory;
    if isempty(csvDirectory), csvDirectory = '.'; end
    exportTable = dailyDemandTable;
    exportTable.date = cellstr(datestr(exportTable.dateNumber,'yyyy-mm-dd'));
    exportTable = exportTable(:, {'date','year','month','dayOfMonth', ...
                                  'monthName', ['meanDemand_' unitLabel]});
    writetable(exportTable, fullfile(csvDirectory,'daily_mean_demand.csv'));
    fprintf('  written: %s\n', fullfile(csvDirectory,'daily_mean_demand.csv'));
end

% Common y limits so months are directly comparable
if options.SameYLim
    axisPadding   = 0.05 * (max(dailyMeanDemand) - min(dailyMeanDemand));
    commonYLimits = [min(dailyMeanDemand)-axisPadding, ...
                     max(dailyMeanDemand)+axisPadding];
else
    commonYLimits = [];
end

uniqueMonths   = unique(calendarData.monthOfDay(:))';
lineColour     = [0.20 0.35 0.55];
meanLineColour = [0.80 0.35 0.20];

% ------------------------------------------------------------------------
% 2. Per-month panels
% ------------------------------------------------------------------------
if strcmpi(options.Layout, 'grid')
    figure('Position',[60 60 1300 850],'Color','w');
    tileLayout = tiledlayout(3, 4, 'TileSpacing','compact', 'Padding','compact');
    title(tileLayout, sprintf('%s - average daily demand by month', siteName), ...
          'FontWeight','bold');
    for currentMonth = uniqueMonths
        nexttile;
        draw_single_month(currentMonth);
    end
    save_figure(gcf, saveDirectory, 'daily_demand_by_month.png');
else
    for currentMonth = uniqueMonths
        figure('Position',[80 80 640 420],'Color','w');
        draw_single_month(currentMonth);
        save_figure(gcf, saveDirectory, ...
            sprintf('daily_demand_%02d_%s.png', currentMonth, ...
                    monthNameList{currentMonth}));
    end
end

% ------------------------------------------------------------------------
% 3. Full-year plot, x axis labelled by month
% ------------------------------------------------------------------------
figure('Position',[100 100 1250 430],'Color','w');
plot(1:numberOfDays, dailyMeanDemand, '-', 'LineWidth',1.1, ...
     'Color',lineColour); hold on; grid on;

% A moving average makes the seasonal trend visible through the daily scatter
if numberOfDays >= 7
    movingAverageWindow = 7;
    movingAverageDemand = movmean(dailyMeanDemand, movingAverageWindow);
    plot(1:numberOfDays, movingAverageDemand, '-', 'LineWidth',2.0, ...
         'Color',meanLineColour);
    legend({'Daily mean', ...
            sprintf('%d-day moving average', movingAverageWindow)}, ...
           'Location','best','FontSize',9);
end

firstDayOfMonth  = zeros(1,numel(uniqueMonths));
middleDayOfMonth = zeros(1,numel(uniqueMonths));
for monthPosition = 1:numel(uniqueMonths)
    daysInThisMonth = find(calendarData.monthOfDay == uniqueMonths(monthPosition));
    firstDayOfMonth(monthPosition)  = daysInThisMonth(1);
    middleDayOfMonth(monthPosition) = daysInThisMonth(1) + ...
                                      floor(numel(daysInThisMonth)/2);
end
for monthPosition = 1:numel(uniqueMonths)
    xline(firstDayOfMonth(monthPosition), ':', 'Color',[0.7 0.7 0.7], ...
          'HandleVisibility','off');
end
xticks(middleDayOfMonth);
xticklabels(cellfun(@(name) name(1:3), monthNameList(uniqueMonths), ...
                    'UniformOutput', false));

xlabel('Month');
ylabel(sprintf('Average daily demand [%s]', unitLabel));
title(sprintf('%s - average daily demand, %d', siteName, calendarData.yearOfDay(1)));
xlim([1 numberOfDays]);

save_figure(gcf, saveDirectory, 'daily_demand_year.png');

% ------------------------------------------------------------------------
    function draw_single_month(monthNumber)
        selectedDays      = (calendarData.monthOfDay == monthNumber);
        dayNumbersInMonth = calendarData.dayOfMonth(selectedDays);
        demandInMonth     = dailyMeanDemand(selectedDays);

        plot(dayNumbersInMonth, demandInMonth, '-o', 'LineWidth',1.2, ...
             'MarkerSize',3, 'Color',lineColour, 'MarkerFaceColor',lineColour);
        hold on; grid on;

        if options.ShowMean
            yline(mean(demandInMonth), '--', 'Color',meanLineColour, ...
                  'LineWidth',1.3, 'Label',sprintf('%.2f',mean(demandInMonth)), ...
                  'LabelHorizontalAlignment','left', 'FontSize',8);
        end

        xlabel('Day of month');
        ylabel(sprintf('Avg demand [%s]', unitLabel));
        title(monthNameList{monthNumber});
        xlim([1 max(dayNumbersInMonth)]);
        if ~isempty(commonYLimits), ylim(commonYLimits); end
    end
end

% =========================================================================
function save_figure(figureHandle, saveDirectory, fileName)
%SAVE_FIGURE  Write a PNG, falling back to print on older MATLAB releases.
if isempty(saveDirectory), return; end
fullFileName = fullfile(saveDirectory, fileName);
try
    exportgraphics(figureHandle, fullFileName, 'Resolution', 200);
catch
    print(figureHandle, fullFileName, '-dpng', '-r200');
end
end
