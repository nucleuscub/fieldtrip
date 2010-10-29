function [mvardata] = ft_mvaranalysis(cfg, data)

% FT_MVARANALYSIS performs multivariate autoregressive modeling on
% time series data over multiple trials.
%
% Use as
%   [mvardata] = ft_mvaranalysis(cfg, data)
%
% The input data should be organised in a structure as obtained from 
% the FT_PREPROCESSING function. The configuration depends on the type 
% of computation that you want to perform.
% The output is a data structure of ft_datatype 'mvar' which contains the
% multivariate autoregressive coefficients in the field coeffs, and the
% covariance of the residuals in the field noisecov. 
%
% The configuration should contain:
%   cfg.toolbox    = the name of the toolbox containing the function for the
%                     actual computation of the ar-coefficients
%                     this can be 'biosig' (default) or 'bsmart'
%                    you should have a copy of the specified toolbox in order
%                     to use mvaranalysis (both can be downloaded directly).
%   cfg.mvarmethod = scalar (only required when cfg.toolbox = 'biosig').
%                     default is 2, relates to the algorithm used for the 
%                     computation of the AR-coefficients by mvar.m
%   cfg.order      = scalar, order of the autoregressive model (default=10)
%   cfg.channel    = 'all' (default) or list of channels for which the model
%                     is fitted.
%   cfg.keeptrials = 'no' (default) or 'yes' specifies whether the coefficients
%                     are estimated for each trial seperately, or on the 
%                     concatenated data
%   cfg.jackknife  = 'no' (default) or 'yes' specifies whether the coefficients
%                     are estimated for all leave-one-out sets of trials 
%   cfg.zscore     = 'no' (default) or 'yes' specifies whether the channel data
%                      are z-transformed prior to the model fit. This may be
%                      necessary if the magnitude of the signals is very different
%                      e.g. when fitting a model to combined MEG/EMG data
%   cfg.blc        = 'yes' (default) or 'no' explicit removal of DC-offset
%
% ft_mvaranalysis can be used to obtain one set of coefficients for 
% the whole common time axis defined in the data. It will throw an error
% if the trials are of variable length, or if the time axes of the trials
% are not equal to one another.
%
% ft_mvaranalysis can be also used to obtain time-dependent sets of
% coefficients based on a sliding window. In this case the input cfg 
% should contain:
%
%   cfg.t_ftimwin = the width of the sliding window on which the coefficients 
%                    are estimated
%   cfg.toi       = [t1 t2 ... tx] the time points at which the windows are 
%                    centered 

% Undocumented local options: 
%   cfg.keeptapers
%   cfg.taper
%   cfg.inputfile  = one can specifiy preanalysed saved data as input
%   cfg.outputfile = one can specify output as file to save to disk   

% Copyright (C) 2009, Jan-Mathijs Schoffelen
%
% This file is part of FieldTrip, see http://www.ru.nl/neuroimaging/fieldtrip
% for the documentation and details.
%
%    FieldTrip is free software: you can redistribute it and/or modify
%    it under the terms of the GNU General Public License as published by
%    the Free Software Foundation, either version 3 of the License, or
%    (at your option) any later version.
%
%    FieldTrip is distributed in the hope that it will be useful,
%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%    GNU General Public License for more details.
%
%    You should have received a copy of the GNU General Public License
%    along with FieldTrip. If not, see <http://www.gnu.org/licenses/>.
%
% $Id$

% set default configurations
if ~isfield(cfg, 'toolbox'),    cfg.toolbox    = 'biosig';       end
if ~isfield(cfg, 'mvarmethod'), cfg.mvarmethod = 2;              end
if ~isfield(cfg, 'order'),      cfg.order      = 10;             end
if ~isfield(cfg, 'channel'),    cfg.channel    = 'all';          end
if ~isfield(cfg, 'keeptrials'), cfg.keeptrials = 'no';           end
if ~isfield(cfg, 'jackknife'),  cfg.jackknife  = 'no';           end
if ~isfield(cfg, 'zscore'),     cfg.zscore     = 'no';           end
if ~isfield(cfg, 'feedback'),   cfg.feedback   = 'textbar';      end
if ~isfield(cfg, 'blc'),        cfg.blc        = 'yes';          end
if ~isfield(cfg, 'toi'),        cfg.toi        = [];             end
if ~isfield(cfg, 't_ftimwin'),  cfg.t_ftimwin  = [];             end
if ~isfield(cfg, 'keeptapers'), cfg.keeptapers = 'yes';          end
if ~isfield(cfg, 'taper'),      cfg.taper      = 'rectwin';      end
if ~isfield(cfg, 'inputfile'),  cfg.inputfile  = [];             end
if ~isfield(cfg, 'outputfile'), cfg.outputfile = [];             end

%check whether the requested toolbox is present
switch cfg.toolbox
  case 'biosig'
    ft_hastoolbox('biosig', 1); 
    nnans  = cfg.order;
  case 'bsmart'
    ft_hastoolbox('bsmart', 1);
    nnans  = 0;
  otherwise
    error('toolbox %s is not yet supported', cfg.toolbox);
end

% load optional given inputfile as data
hasdata = (nargin>1);
if ~isempty(cfg.inputfile)
  % the input data should be read from file
  if hasdata
    error('cfg.inputfile should not be used in conjunction with giving input data to this function');
  else
    data = loadvar(cfg.inputfile, 'data');
  end
end

%check the input-data
data = ft_checkdata(data, 'datatype', 'raw', 'hastrialdef', 'yes');

%check configurations
switch cfg.toolbox
  case 'biosig'
    cfg = ft_checkconfig(cfg, 'required', 'mvarmethod');
  case 'bsmart'
    %nothing extra required
end

if isempty(cfg.toi) && isempty(cfg.t_ftimwin)
  %fit model to entire data segment
  ok = 1;
  for k = 1:numel(data.trial)
    if any(data.time{k}~=data.time{1}),
      ok = 0;
      break
    end
  end

  if ~ok
    error('time axes of all trials should be identical');
  else
    cfg.toi       = mean(data.time{1}([1 end]))       + 0.5/data.fsample;
    cfg.t_ftimwin = data.time{1}(end)-data.time{1}(1) + 1/data.fsample;
  end
    
elseif ~isempty(cfg.toi) && ~isempty(cfg.t_ftimwin)
  %do sliding window approach
else
  error('cfg should contain both cfg.toi and cfg.t_ftimwin');
end  

cfg.channel = ft_channelselection(cfg.channel, data.label);

keeprpt  = strcmp(cfg.keeptrials, 'yes');
keeptap  = strcmp(cfg.keeptapers, 'yes');
dojack   = strcmp(cfg.jackknife,  'yes');
dozscore = strcmp(cfg.zscore,     'yes');

if ~keeptap, error('not keeping tapers is not possible yet'); end
if dojack && keeprpt, error('you cannot simultaneously keep trials and do jackknifing'); end

tfwin    = round(data.fsample.*cfg.t_ftimwin);
ntrl     = length(data.trial);
ntoi     = length(cfg.toi);
chanindx = match_str(data.label, cfg.channel);
nchan    = length(chanindx);
label    = data.label(chanindx);

ncmb     = nchan*nchan;
cmbindx1 = repmat(chanindx(:),  [1 nchan]);
cmbindx2 = repmat(chanindx(:)', [nchan 1]);
labelcmb = [data.label(cmbindx1(:)) data.label(cmbindx2(:))];

%---think whether this makes sense at all
if strcmp(cfg.taper, 'dpss')
  % create a sequence of DPSS (Slepian) tapers
  % ensure that the input arguments are double precision
  tap = double_dpss(tfwin,tfwin*(cfg.tapsmofrq./data.fsample))';
  tap = tap(1,:); %only use first 'zero-order' taper
elseif strcmp(cfg.taper, 'sine')
  tap = sine_taper(tfwin, tfwin*(cfg.tapsmofrq./data.fsample))';
  tap = tap(1,:);
else
  tap = window(cfg.taper, tfwin)';
  tap = tap./norm(tap);
end
ntap = size(tap,1);

%---preprocess data if necessary
%---blc
if strcmp(cfg.blc, 'yes'),
  tmpcfg           = [];
  tmpcfg.blc       = 'yes';
  tmpcfg.blcwindow = cfg.toi([1 end]) + cfg.t_ftimwin.*[-0.5 0.5];
  data             = ft_preprocessing(tmpcfg, data);
else
  %do nothing
end

%---zscore
if dozscore,
  zwindow = cfg.toi([1 end]) + cfg.t_ftimwin.*[-0.5 0.5];
  sumval  = 0;
  sumsqr  = 0;
  numsmp  = 0;
  trlindx = [];
  for k = 1:ntrl
    begsmp = nearest(data.time{k}, zwindow(1));
    endsmp = nearest(data.time{k}, zwindow(2));
    if endsmp>=begsmp,
      sumval  = sumval + sum(data.trial{k}(:, begsmp:endsmp),    2);
      sumsqr  = sumsqr + sum(data.trial{k}(:, begsmp:endsmp).^2, 2);
      numsmp  = numsmp + endsmp - begsmp + 1;
      trlindx = [trlindx; k];
    end
  end
  datavg = sumval./numsmp;
  datstd = sqrt(sumsqr./numsmp - (sumval./numsmp).^2);
  
  data.trial = data.trial(trlindx);
  data.time  = data.time(trlindx);
  ntrl       = length(trlindx);
  for k = 1:ntrl
    rvec          = ones(1,size(data.trial{k},2));
    data.trial{k} = (data.trial{k} - datavg*rvec)./(datstd*rvec);
  end
else
  %do nothing
end

%---generate time axis
maxtim = -inf;
mintim = inf;
for k = 1:ntrl
  maxtim = max(maxtim, data.time{k}(end));
  mintim = min(mintim, data.time{k}(1));
end
timeaxis = mintim:1/data.fsample:maxtim;

%---allocate memory
if keeprpt || dojack
  coeffs   = zeros(length(data.trial), nchan, nchan, cfg.order, ntoi, ntap);
  noisecov = zeros(length(data.trial), nchan, nchan,            ntoi, ntap);
else
  coeffs   = zeros(1, nchan, nchan, cfg.order, ntoi, ntap);
  noisecov = zeros(1, nchan, nchan,            ntoi, ntap);
end

%---loop over the tois
ft_progress('init', cfg.feedback, 'computing MAR-model');
for j = 1:ntoi
  ft_progress(j/ntoi, 'processing timewindow %d from %d\n', j, ntoi);
  sample        = nearest(timeaxis, cfg.toi(j));
  cfg.toi(j)    = timeaxis(sample);
  
  tmpcfg        = [];
  tmpcfg.toilim = [timeaxis(sample-floor(tfwin/2)) timeaxis(sample+ceil(tfwin/2)-1)];
  tmpcfg.feedback = 'no';
  tmpcfg.minlength= 'maxperlen';
  tmpdata       = ft_redefinetrial(tmpcfg, data);
  
  cfg.toi(j)    = mean(tmpdata.time{1}([1 end]))+0.5./data.fsample; %FIXME think about this

  %---create cell-array indexing which original trials should go into each replicate
  rpt  = {};
  nrpt = numel(tmpdata.trial);
  if dojack
    rpt = cell(nrpt,1);
    for k = 1:nrpt
      rpt{k,1} = setdiff(1:nrpt,k);
    end
  elseif keeprpt
    for k = 1:nrpt
      rpt{k,1} = k;
    end
  else
    rpt{1} = 1:numel(tmpdata.trial);
    nrpt   = 1;
  end
    
  for rlop = 1:nrpt

    for m = 1:ntap
      %---construct data-matrix
      dat = catnan(tmpdata.trial, chanindx, rpt{rlop}, tap(m,:), nnans);
      
      %---estimate autoregressive model
      switch cfg.toolbox
        case 'biosig'
          [ar, rc, pe] = mvar(dat', cfg.order, cfg.mvarmethod);
   
          %---compute noise covariance
          tmpnoisecov     = pe(:,nchan*cfg.order+1:nchan*(cfg.order+1));
        case 'bsmart'
          [ar, tmpnoisecov] = armorf(dat, numel(rpt{rlop}), size(tmpdata.trial{1},2), cfg.order);      
          ar = -ar; %convention is swapped sign with respect to biosig
          %FIXME check which is which: X(t) = A1*X(t-1) + ... + An*X(t-n) + E
          %the other is then X(t) + A1*X(t-1) + ... + An*X(t-n) = E 
      end
      coeffs(rlop,:,:,:,j,m) = reshape(ar, [nchan nchan cfg.order]);
      
      %---rescale noisecov if necessary
      if dozscore,
        noisecov(rlop,:,:,j,m) = diag(datstd)*tmpnoisecov*diag(datstd);
      else
        noisecov(rlop,:,:,j,m) = tmpnoisecov;
      end
      dof(rlop,:,j) = numel(rpt{rlop});
    end %---tapers
  
  end %---replicates

end %---tois 
ft_progress('close');

%---create output-structure
mvardata          = [];

if dojack,
  mvardata.dimord = 'rptjck_chan_chan_lag';
elseif keeprpt
  mvardata.dimord = 'rpt_chan_chan_lag';
else
  mvardata.dimord = 'chan_chan_lag';
  siz    = size(coeffs);
  coeffs = reshape(coeffs, siz(2:end));
  siz    = size(noisecov);
  noisecov = reshape(noisecov, siz(2:end));
end  
mvardata.coeffs   = coeffs;
mvardata.noisecov = noisecov;
mvardata.dof      = dof;
mvardata.label    = label;
if numel(cfg.toi)>1
  mvardata.time   = cfg.toi;
  mvardata.dimord = [mvardata.dimord,'_time'];
end
mvardata.fsampleorig = data.fsample;

% accessing this field here is needed for the configuration tracking
% by accessing it once, it will not be removed from the output cfg
cfg.outputfile;

% get the output cfg
cfg = ft_checkconfig(cfg, 'trackconfig', 'off', 'checksize', 'yes');

% add version information to the configuration
cfg.version.name = mfilename('fullpath');
cfg.version.id   = '$Id$';

% remember the configuration details of the input data
try 
  cfg.previous = data.cfg;
end

mvardata.cfg = cfg;

% the output data should be saved to a MATLAB file
if ~isempty(cfg.outputfile)
  savevar(cfg.outputfile, 'data', mvardata); % use the variable name "data" in the output file
end

%----------------------------------------------------
%subfunction to concatenate data with nans in between
function [datamatrix] = catnan(datacells, chanindx, trials, taper, nnans)

nchan = numel(chanindx);
nsmp  = size(datacells{1}, 2);
nrpt  = numel(trials);

%---initialize
datamatrix = zeros(nchan, nsmp*nrpt + nnans*(nrpt-1)) + nan;

%---fill the matrix
for k = 1:nrpt
  if k==1,
    begsmp = (k-1)*nsmp + 1;
    endsmp =  k   *nsmp    ;
  else
    begsmp = (k-1)*(nsmp+nnans) + 1;
    endsmp =  k   *(nsmp+nnans) - nnans;
  end
  datamatrix(:,begsmp:endsmp) = datacells{trials(k)}(chanindx,:).*taper(ones(nchan,1),:);
end

%------------------------------------------------------
%---subfunction to ensure that the first two input arguments are of double
% precision this prevents an instability (bug) in the computation of the
% tapers for Matlab 6.5 and 7.0
function [tap] = double_dpss(a, b, varargin)
tap = dpss(double(a), double(b), varargin{:});
