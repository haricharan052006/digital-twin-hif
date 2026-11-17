function capture_twin_canvas()
%CAPTURE_TWIN_CANVAS  Top-level canvas of ieee13_hif_twin_system.slx as it is
% now (with the breaker delays and the relay interlock), for the report.
% The model is loaded and printed only, never saved.
%
% Output: results/report_figures/fig_cmp_model_canvas.png
root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'scripts'), fullfile(root, 'models'));
sys = 'ieee13_hif_twin_system';
load_system(fullfile(root, 'models', [sys '.slx']));
print(['-s' sys], '-dpng', '-r150', fullfile(root, 'results', 'report_figures', 'fig_cmp_model_canvas.png'));
close_system(sys, 0);
fprintf('Saved fig_cmp_model_canvas.png\n');
end
