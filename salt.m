% salt  ENDOR spectra simulation 
%
%   salt(Sys,Exp)
%   salt(Sys,Exp,Opt)
%   spec = salt(...)
%   [rf,spec] = salt(...)
%   [rf,spec,Trans] = salt(...)
%
%   Input:
%   - Sys: spin system structure specification
%       S, g, Nucs, A, Apa, Q, Qpa etc.
%       lwEndor     FWHM Endor line width [Gaussian,Lorentzian]
%   - Exp: experiment specification
%       mwFreq        spectrometer frequency, in GHz
%       Field         magnetic field, in mT
%       Range         radiofrequency range [low,high], in MHz
%       nPoints       number of points
%       Temperature   temperature of the sample, by default off (NaN)
%       ExciteWidth   ENDOR excitation width, FWHM, in MHz
%       Orientations  orientations for single-crystal simulations
%       Ordering      coefficient for non-isotropic orientational distribution
%   - Opt: simulation options
%       Transitions, Threshold, Symmetry
%       nKnots, Intensity, Enhancement, Output
%       ThetaRange
%
%   Output:
%   - rf:     the radiofrequency axis, in MHz
%   - spec:   the spectrum or spectra
%   - Trans:  level number pairs of the transitions in spec
%   If no output argument is given, the simulated spectrum is plotted.

function varargout = salt(Sys,Exp,Opt)

if (nargin==0), help(mfilename); return; end

% Get time for performance prompt at the end.
StartTime = clock;

% Check Matlab version.
error(chkmlver);

% --------License ------------------------------------------------
LicErr = 'Could not determine license.';
Link = 'epr@eth'; eschecker; error(LicErr); clear Link LicErr
% --------License ------------------------------------------------

% Check the number of input and output arguments.
if (nargin<2) || (nargin>3), error('Wrong number of input arguments!'); end
if (nargout<0), error('Not enough output arguments.'); end
if (nargout>3), error('Too many output arguments.'); end

% Supplement empty options structure if not given.
if (nargin<3), Opt = struct('unused',NaN); end
if isempty(Opt), Opt = struct('unused',NaN); end

if ~isstruct(Sys) && ~iscell(Sys)
  error('Sys must be a structure or a list of structures!');
end
if ~isstruct(Exp)
  error('Exp must be a structure!');
end
if ~isstruct(Opt)
  error('Opt must be a structure!');
end

% A global variable sets the level of log display. The global variable
% is used in logmsg(), which does the display.
if ~isfield(Opt,'Verbosity'), Opt.Verbosity = 0; end
global EasySpinLogLevel;
EasySpinLogLevel = Opt.Verbosity;


%==================================================================
% Loop over species and isotopologues
%==================================================================
FrequencyAutoRange = (~isfield(Exp,'Range') || isempty(Exp.Range)) && ...
  (~isfield(Exp,'CenterSweep') || isempty(Exp.CenterSweep));
if ~isfield(Opt,'IsoCutoff'), Opt.IsoCutoff = 1e-4; end

if ~isfield(Sys,'singleiso')

  [SysList,weight] = expandcomponents(Sys,Opt.IsoCutoff);
  
  if (numel(SysList)>1) && FrequencyAutoRange
    error('Multiple components: Please specify frequency range manually using Exp.Range or Exp.CenterSweep.');
  end
  
  spec = 0;
  for iComponent = 1:numel(SysList)
    [xAxis,spec_,Transitions] = salt(SysList{iComponent},Exp,Opt);
    spec = spec + spec_*weight(iComponent);
  end
  
  % Output and plotting
  switch (nargout)
    case 0,
      cla
      plot(xAxis,spec);
      axis tight
      xlabel('frequency (MHz)');
      ylabel('intensity (arb.u.)');
      if isfield(Exp,'mwFreq') && ~isnan(Exp.mwFreq)
        title(sprintf('ENDOR at %0.8g GHz and %0.8g mT',Exp.mwFreq,Exp.Field));
      else
        title(sprintf('ENDOR at %0.8g mT',Exp.Field));
      end
    case 1, varargout = {spec};
    case 2, varargout = {xAxis,spec};
    case 3, varargout = {xAxis,spec,Transitions};
  end
  return
end
%==================================================================


logmsg(1,'=begin=salt=======%s=================',datestr(now));
logmsg(2,'  log level %d',EasySpinLogLevel);
logmsg(1,'-general-----------------------------------------------');


% Processing spin system structure
%==========================================================================
if ~isfield(Sys,'Nucs'), Sys.Nucs = ''; end
out = isotopologues(Sys.Nucs);
if (out.nIso>1)
  error('salt does not support isotope mixtures. Please specify pure isotopes in Sys.Nucs.');
end

[Sys,err] = validatespinsys(Sys);
error(err);

ConvWidth = any(Sys.lwEndor>0);

logmsg(1,'  system with %d electron spin(s), %d nuclear spin(s), total %d states',...
  Sys.nElectrons,Sys.nNuclei,Sys.nStates);

if isfield(Sys,'ExciteWidth')
  error('You gave Sys.ExciteWidth, but it should be Exp.ExciteWidth. Please correct.');
end
%==========================================================================


% Method: 'matrix' or 'perturb', 'perturb1', 'perturb2'
if ~isfield(Opt,'Method'), Opt.Method = 'matrix'; end
Method = parseoption(Opt,'Method',{'matrix','perturb','perturb1','perturb2'});
switch Method
  case 1, Opt.PerturbOrder = 0; Method = 1;
  case 2, Opt.PerturbOrder = 1; Method = 2;
  case 3, Opt.PerturbOrder = 1; Method = 2;
  case 4, Opt.PerturbOrder = 2; Method = 2;
end

%=======================================================================
% Experiment structure, contains experimental settings
%=======================================================================

% Documented fields and their defaults (mandatory parameters are set to NaN)
DefaultExp.Field = NaN;
DefaultExp.mwFreq = NaN;
DefaultExp.Range = NaN;
DefaultExp.CenterSweep = NaN;
DefaultExp.nPoints = 1024;
DefaultExp.Temperature = NaN;
DefaultExp.ExciteWidth = inf;
DefaultExp.Orientations = [];
DefaultExp.Ordering = [];
DefaultExp.CrystalSymmetry = '';

% Undocumented and unused fields
DefaultExp.Harmonic = 0;

% Make user-given fields case-insensitive.
Exp = adddefaults(Exp,DefaultExp);

% Error if vital parameters are missing.
if isnan(Exp.Field), error('Experiment.Field is missing!'); end
  
if isnan(Exp.mwFreq)
  if ~isinf(Exp.ExciteWidth)
    error('Experiment.mwFreq is missing! It is needed, since Exp.ExciteWidth is given.');
  end
end

AutoRange = isnan(Exp.Range)& isnan(Exp.CenterSweep);
if (Method==1)
%  if AutoRange, error('Cannot automatically determine rf range. Please specify Exp.Range or Exp.CenterSweep.'); end
end

% Check both CenterSweep and Range, prefer CenterSweep
if ~isnan(Exp.CenterSweep)
  if ~isnan(Exp.Range)
    logmsg(0,'Using Experiment.CenterSweep and ignoring Experiment.Range.');
  end
  if (Exp.CenterSweep(2)<=0)
    error('Sweep range in Exp.CenterSweep must be positive.');
  end
  Exp.Range = Exp.CenterSweep(1) + [-1 1]*Exp.CenterSweep(2)/2;
  if (Exp.Range(1)<0)
    error('Start value resulting from Exp.CenterSweep is negative (%g).',Exp.Range(1));
  end
end

% Check Exp.Range
if ~isnan(Exp.Range)
  if any(diff(Exp.Range)<=0) || ...
      any(~isfinite(Exp.Range)) || ...
      any(~isreal(Exp.Range)) || ...
      any(Exp.Range<0) || ...
      (numel(Exp.Range)~=2)
    error('Experiment.Range is not valid!');
  end
end

% Automatic on-resonance setting: (1) isotropic g, (2) mwFreq==0
if (Exp.mwFreq==0) && (all(diff(Sys.g)==0))
  Exp.mwFreq = mean(Sys.g)*bmagn*Exp.Field*1e-3/planck/1e9;
end

% Exp.Orientations gives orientations for single-crystal computations
if isfield(Exp,'Orientation')
  disp('Exp.Orientation given, did you mean Exp.Orientations?');
end
PowderSimulation = isempty(Exp.Orientations);
if (~PowderSimulation)
  % Make sure Exp.Orientations is ok
  [n1,n2] = size(Exp.Orientations);
  % Transpose array if nx2 or nx3 array is given with n==1 or n>3
  if ((n2==2)||(n2==3)) && (n1~=2) && (n1~=3)
    Exp.Orientations = Exp.Orientations.';
  end
  [nAngles,nOrientations] = size(Exp.Orientations);
  if (nAngles<2) || (nAngles>3)
    error('Exp.Orientations array has %d rows instead of 2 or 3.',nAngles);
  end
end

if ~isempty(Exp.Ordering)
  if isnumeric(Exp.Ordering) && (numel(Exp.Ordering)==1) && isreal(Exp.Ordering)
    OrderingFcn = 0;
    logmsg(1,'  partial order (built-in function, lambda = %g)',Exp.Ordering);
  elseif isa(Exp.Ordering,'function_handle')
    OrderingFcn = 1;
    logmsg(1,'  partial order (user-supplied function)');
  else
    error('Exp.Ordering must be a single number or a function handle.');
  end
end

if (EasySpinLogLevel>=1)
  if ~AutoRange
    msg = sprintf('field %g mT, rf range [%g %g] MHz, %d points',...
      Exp.Field,Exp.Range(1),Exp.Range(2),Exp.nPoints);
  else
    msg = sprintf('field %g mT, automatic rf range, %d points',...
      Exp.Field,Exp.nPoints);
  end
  if ~isnan(Exp.mwFreq)
    msg = sprintf('mw %g GHz, %s',Exp.mwFreq,msg);
  else
    msg = sprintf('mw not given, %s',msg);
  end
  logmsg(1,['  ' msg]);
end

NonEquiPops = 0;
if isfinite(Exp.Temperature)
  msg = sprintf('  temperature %g K',Exp.Temperature);
else
  msg = '  no temperature';
end
logmsg(1,msg);

if (Exp.Harmonic>0) && all(Sys.lwEndor==0)
  logmsg(-inf,'WARNING: Cannot compute derivative of a stick spectrum! Returning absorption spectrum.');
  logmsg(-inf,'WARNING:   Add a line width (strain or convolution) or set Harmonic=0.');
  Exp.Harmonic = 0;
end

if isfield(Exp,'HStrain')
  error('You gave Exp.HStrain, but it should be Sys.HStrain. Please correct.');
end

if isfield(Exp,'Orientation')
  disp('Exp.Orientation given, did you mean Exp.Orientations?');
end


%==========================================================================


% Processing Options structure
%==========================================================================
% Documented fields, endorfrq (for defaults see there!)
%DefaultOpt.Transitions = []; % endorfrq
%DefaultOpt.Threshold = 5e-4; % endorfrq
%DefaultOpt.Nuclei = []; % endorfrq
%DefaultOpt.Intensity = 'on'; % endorfrq
%DefaultOpt.Enhancement = 'off'; % endorfrq

% Documented fields, salt
if (Method==2)
  DefaultOpt.nKnots = [61 0];
else
  DefaultOpt.nKnots = [31 3];
end
DefaultOpt.Symmetry = 'auto';
DefaultOpt.SymmFrame = [];
DefaultOpt.Output = 'summed';
DefaultOpt.ThetaRange = [];

% Undocumented fields
DefaultOpt.nTRKnots = 4; % endorfrq
DefaultOpt.Smoothing = 2;
DefaultOpt.minEffKnots = 5;

% Undocumented fields
DefaultOpt.OriWeights = [];
DefaultOpt.OriThreshold = 1e-4;
DefaultOpt.IncludeOriWeights = 1;
DefaultOpt.OriPreSelect = [];
DefaultOpt.PaddingMultiplier = 3; % for padding before convolution

% Supplement the user-supplied structure with the defaults
Opt = adddefaults(Opt,DefaultOpt);
if numel(Opt.nKnots)<2, Opt.nKnots(2) = DefaultOpt.nKnots(2); end

% Parse and process options with string values.
%IntensitySwitch = parseoption(Opt,'Intensity',{'off','on'}) - 1;
%EnhancementSwitch = parseoption(Opt,'Enhancement',{'off','on'}) -1;
SummedOutput = (1==parseoption(Opt,'Output',{'summed','separate'}));


SuppliedOriWeights = ~isempty(Opt.OriWeights);
if SuppliedOriWeights
  Opt.OriWeights = Opt.OriWeights(:).';
end
if ~isempty(Opt.ThetaRange) && SuppliedOriWeights
  error('You cannot use ThetaRange and OriWeights simultaneously!');
end
if Opt.OriPreSelect & SuppliedOriWeights
  error('You cannot use OriPreSelect and supply OriWeights simultaneously!');
end

% Error if obsolete option is specified
if isfield(Opt,'Convolution')
  error('Options.Convolution is obsolete! Please remove from code!');
end

if isfield(Opt,'Width')
  error('Options.Width is obsolete! Please remove from code.');
end

if isfield(Opt,'nSpline')
  error('Options.nSpline is obsolete. Use a second number in Options.nKnots instead, e.g. Options.nKnots = [19 5] for Options.nSpline = 5.');
end

if isfield(Opt,'LineShape')
  error('Options.LineShape is obsolete. Use System.lwEndor instead.');
end

if strcmpi(Opt.Symmetry,'auto')
  Opt.Symmetry = [];
end

%==========================================================================

%====================================================================
% Special case: no nuclei
%--------------------------------------------------------------
if (Sys.nNuclei==0)
  Exp.deltaX = diff(Exp.Range)/(Exp.nPoints-1);
  xAxis = Exp.Range(1) + (0:Exp.nPoints-1)*Exp.deltaX;
  spec = zeros(1,Exp.nPoints);
  Transitions = [];
  switch (nargout)
    case 0,
      cla
      plot(xAxis,spec);
      axis tight
      xlabel('frequency (MHz)');
      ylabel('intensity (arb.u.)');
      if ~isnan(Exp.mwFreq)
        title(sprintf('ENDOR at %0.8g GHz and %0.8g mT',Exp.mwFreq,Exp.Field));
      else
        title(sprintf('ENDOR at %0.8g mT',Exp.Field));
      end
    case 1, varargout = {spec};
    case 2, varargout = {xAxis,spec};
    case 3, varargout = {xAxis,spec,Transitions};
  end
  return
end
%====================================================================

p_symandgrid;


%==========================================================================
% Orientation pre-selection
%==========================================================================
% Based on a reduced spin system, weights are computed for orientation.
% They indicate whether any EPR transition is excited for that orientation
% or not. Based on the weight for a particular orientation and on
% Opt.OriThreshold, endorfrq will decide whether to compute the ENDOR
% spectrum.

Opt.DoPreSelection = PowderSimulation & Opt.OriPreSelect & ...
  (Opt.OriThreshold>0) & isempty(Opt.OriWeights);

if (Opt.DoPreSelection)
  logmsg(1,'  computing orientations which fall into excitation window');
  OriSys = anisosubsys(Sys);
  OriExp = Exp;
  OriExp.Orientations = [phi;theta];
  Opt.OriWeights = orisel(OriSys,OriExp);
  Opt.OriWeights = Opt.OriWeights/max(Opt.OriWeights);
  str = '  %g percent of all orientations above relative threshold %g';
  logmsg(1,sprintf(str,100*sum(Opt.OriWeights>Opt.OriThreshold)/nOrientations,Opt.OriThreshold));
  %plot(theta*180/pi,Opt.OriWeights)
end
%==========================================================================



%=======================================================================
%=======================================================================
%                   PEAK DATA COMPUTATION
%=======================================================================
%=======================================================================

logmsg(1,'-resonances--------------------------------------------');
MethodName = {'  method: matrix diagonalization','  method: perturbation theory'};
logmsg(1,MethodName{Method});
logmsg(2,'  -endorfrq start-----------------------------------');
Opt.saltcall = 1;
Exp.Orientations = [phi;theta;chi];
switch Method
  case 1, [Pdat,Idat,Transitions,Info] = endorfrq(Sys,Exp,Opt);
  case 2, [Pdat,Idat,Transitions,Info] = endorfrq_perturb(Sys,Exp,Opt);
end
logmsg(2,'  -endorfrq end-------------------------------------');
nTransitions = size(Pdat,1);
AnisotropicWidths = 0;

if (nTransitions==0)
  err = sprintf(['No ENDOR resonances between %g and %g MHz (%g mT).\n'...
      'Check frequency range, magnetic field and transition selection.'],...
    Exp.Range(1),Exp.Range(2),Exp.Field);
  error(err);
end
logmsg(1,'  %d transitions with resonances in range',nTransitions);
logmsg(2,'  positions min %g MHz, max %g MHz',min(Pdat(:)),max(Pdat(:)));

AnisotropicIntensities = numel(Idat)>1;
if (AnisotropicIntensities)
  logmsg(2,'  amplitudes min %g, max %g',min(Idat(:)),max(Idat(:)));
end

if (SuppliedOriWeights)
  logmsg(1,'  user supplied OriWeights: including them in intensity');
  if Opt.IncludeOriWeights
    for iT = 1:nTransitions
      Idat(iT,:) = Idat(iT,:).*Opt.OriWeights;
    end
  end
end

if (~PowderSimulation) && ~isempty(Exp.CrystalSymmetry)
  nSites = numel(Pdat)/nTransitions/nOrientations;
else
  nSites = 1;
end

if AutoRange
  Range = [min(Pdat(:)) max(Pdat(:))]+[-1 1]*max(Sys.lwEndor)*2;
  Range = Range + diff(Range)*[-1 1]*0.2;
  Range(1) = max(Range(1),0); 
  Exp.Range = Range;
end
Exp.deltaX = diff(Exp.Range)/(Exp.nPoints-1); % includes last value
xAxis = Exp.Range(1) + (0:Exp.nPoints-1)*Exp.deltaX;

%=======================================================================
%=======================================================================



% Guard against strong orientation selectivity.
%----------------------------------------------------------------------------
% If the width of the EPR spectrum is much greater than the excitation width,
% interpolation and projection is not advisable.

if (Info.Selectivity>0)
  logmsg(1,'  orientation selection: %g (<1 very weak, 1 weak, 10 strong, >10 very strong)',Info.Selectivity);
  GridTooCoarse = (Opt.nKnots(1)/Opt.minEffKnots<Info.Selectivity);
  if GridTooCoarse && PowderSimulation
    fprintf('  ** Warning: Strong orientation selection ********************************\n');
    fprintf('  Only %0.1f orientations in excitation window! Spectrum might be inaccurate.\n',Opt.nKnots(1)/Info.Selectivity);
    fprintf('  Increase Opt.nKnots (currently %d) or increase\n',Opt.nKnots(1));
    fprintf('  Exp.ExciteWidth (currently %g MHz).\n',Exp.ExciteWidth);
    fprintf('  *************************************************************************\n');
  end
else
  logmsg(1,'  orientation selection: none');
end

%=======================================================================
%=======================================================================
%               INTERPOLATION AND SPECTRUM CONSTRUCTION
%=======================================================================
%=======================================================================
% The position/amplitude/width data from above are
%     (1) interpolated to get more of them, and then
%     (2) projected to obtain the spectrum
% The interpolation and projection algorithms depend
% on the symmetry of the data.

logmsg(1,'-absorption spectrum construction----------------------');

NaN_in_Pdat = any(isnan(Pdat),2);
if any(NaN_in_Pdat)
  Opt.nKnots(2) = 1;
end

BruteForceSum = 0;

if (~BruteForceSum)

% Determine methods: projection/summation, interpolation on/off
%-----------------------------------------------------------------------
DoProjection = (~AnisotropicWidths) & (nOctants>=0);
%DoProjection = DoProjection & ~GridTooCoarse & ~skippedOris & ~openPhi;

DoInterpolation = (Opt.nKnots(2)>1) & (nOctants>=0);
%DoInterpolation = DoInterpolation & ~skippedOris & ~GridTooCoarse;

% Preparations for projection
%-----------------------------------------------------------------------
if (DoProjection)
  msg = 'triangle/segment projection';
else
  msg = 'summation';
  Template.x = 5e4;
  Template.lw = Template.x/2.5; %<1e-8 at borders for Harmonic = -1
  Template.y = gaussian(0:2*Template.x-1,Template.x,Template.lw,-1);
end
Text = {'single-crystal','isotropic','axial','nonaxial D2h','nonaxial C2h','','nonaxial Ci'};
logmsg(1,'  %s, %s case',msg,Text{nOctants+3});

% Preparations for interpolation
%-----------------------------------------------------------------------
if (DoInterpolation)
  % Set an option for the sparse tridiagonal matrix \ solver in global cubic
  % spline interpolation. This function needs some time, so it was taken
  % out of Matlab's original spline() function, which is called many times.
  spparms('autommd',0);
  % Interpolation parameters. 1st char: g global, l linear. 2nd char: order.
  if (nOctants==0), % axial symmetry: 1D interpolation
    if any(NaN_in_Pdat)
      InterpMode = {'L3','L3','L3'};
    else
      InterpMode = {'G3','L3','L3'};
    end
  else % 2D interpolation (no L3 method available)
    if any(NaN_in_Pdat)
      InterpMode = {'L1','L1','L1'};
    else
      InterpMode = {'G3','L1','L1'};
    end
  end
  msg = sprintf('  interpolation (factor %d, method %s/%s/%s)',Opt.nKnots(2),InterpMode{1},InterpMode{2},InterpMode{3});
else
  Opt.nKnots(2) = 1;
  msg = '  interpolation off';
end
nfKnots = (Opt.nKnots(1)-1)*Opt.nKnots(2) + 1;
logmsg(1,msg);

% Pre-allocation of spectral array.
%-----------------------------------------------------------------------
if (SummedOutput)
  nRows = 1;
  msg = 'summed';
else
  if (~PowderSimulation)
    nRows = nOrientations;
  else
    nRows = nTransitions;
  end
  msg = 'separate';
end
spec = zeros(nRows,Exp.nPoints);
logmsg(1,'  spectrum array size: %dx%d (%s)',size(spec,1),size(spec,2),msg);


% Spectrum construction
%-----------------------------------------------------------------------
if (~PowderSimulation)
  %=======================================================================
  % Single-crystal spectra
  %=======================================================================
  
  if (~AnisotropicIntensities), thisInt = ones(nTransitions,1); end
  if (~AnisotropicWidths), thisWid = zeros(nTransitions,1); end
  
  idx = 1;
  for iOri = 1:nOrientations
    for iSite = 1:nSites
      %logmsg(3,'  orientation %d of %d',iOri,nOrientations);

      thisPos = Pdat(:,idx);
      if (AnisotropicIntensities), thisInt = Idat(:,idx); end
      %if (AnisotropicWidths), thisWid = Wdat(:,idx); end

      thisspec = lisum1i(Template.y,Template.x,Template.lw,thisPos,thisInt,thisWid,xAxis);
      thisspec = (8*pi^2)*thisspec; % for consistency with powder spectra (factor from integral over phi,theta,chi)

      if (SummedOutput)
        spec = spec + thisspec;
      else
        spec(iOri,:) = spec(iOri,:) + thisspec;
      end

      idx = idx + 1;
    end
  end
  
elseif (nOctants==-1)

  %=======================================================================
  % Isotropic powder spectra
  %=======================================================================

  if (~AnisotropicIntensities), thisInt = Idat; end
  if (~AnisotropicWidths), thisWid = 0; end
  
  for iTrans = 1:nTransitions
    %logmsg(3,'  transition %d of %d',iTrans,nTransitions);
    
    thisPos = Pdat(iTrans,:);
    if (AnisotropicIntensities), thisInt = Idat(iTrans,:); end
    %if (AnisotropicWidths), thisWid = Wdat(iTrans,:); end
    
    thisspec = lisum1i(Template.y,Template.x,Template.lw,thisPos,thisInt,thisWid,xAxis);
    thisspec = thisspec*(8*pi^2); % powder integral (phi,theta,chi)
    
    if (SummedOutput)
      spec = spec + thisspec;
    else
      spec(iTrans,:) = thisspec;
    end

  end

else
  
  %=======================================================================
  % Powder spectra: interpolation and accumulation/projection
  %=======================================================================
  Axial = (nOctants==0);
  if (Axial)
    if (DoInterpolation)
      [fphi,fthe] = sphgrid(Opt.Symmetry,nfKnots,'f');
    else
      fthe = theta;
    end
    fSegWeights = -diff(cos(fthe))*4*pi; % sum is 4*pi
    if ~isempty(Exp.Ordering)
      centreTheta = (fthe(1:end-1)+fthe(2:end))/2;
      if (OrderingFcn)
        OrderingWeights = feval(Exp.Ordering,zeros(1,numel(centreTheta)),centreTheta);
        %OrderingWeights = Exp.Ordering(zeros(1,numel(centreTheta)),centreTheta);
        if any(OrderingWeights)<0, error('User-supplied orientation distribution gives negative values!'); end
        if max(OrderingWeights)==0, error('User-supplied orientation distribution is all-zero.'); end
      else
        OrderingWeights = exp(Exp.Ordering*plegendre(2,0,cos(centreTheta)));
      end
      fSegWeights = fSegWeights(:).*OrderingWeights(:);
      fSegWeights = 4*pi/sum(fSegWeights)*fSegWeights;
    elseif ~isempty(Opt.ThetaRange)
      centreTheta = (fthe(1:end-1)+fthe(2:end))/2;
      idx = (centreTheta<Opt.ThetaRange(1)) | (centreTheta>Opt.ThetaRange(2));
      fSegWeights(idx) = 0;
    end
    logmsg(1,'  total %d segments, %d transitions',numel(fthe)-1,nTransitions);
    
  else % nonaxial symmetry
    if (DoInterpolation)
      [fphi,fthe] = sphgrid(Opt.Symmetry,nfKnots,'f');
    else
      fthe = theta;
      fphi = phi;
    end
    [idxTri,Areas] = triangles(nOctants,nfKnots,ang2vec(fphi,fthe));
    if ~isempty(Exp.Ordering)
      centreTheta = mean(fthe(idxTri));
      if (OrderingFcn)
        centrePhi = mean(fphi(idxTri));
        OrderingWeights = feval(Exp.Ordering,centrePhi,centreTheta);
        %OrderingWeights = Exp.Ordering(centrePhi,centreTheta);
        if any(OrderingWeights)<0, error('User-supplied orientation distribution gives negative values!'); end
        if max(OrderingWeights)==0, error('User-supplied orientation distribution is all-zero.'); end
      else
        OrderingWeights = exp(Exp.Ordering*plegendre(2,0,cos(centreTheta)));
      end
      Areas = Areas(:).*OrderingWeights(:);
      Areas = 4*pi/sum(Areas)*Areas;
    elseif ~isempty(Opt.ThetaRange)
      centreTheta = mean(fthe(idxTri));
      idx = (centreTheta<Opt.ThetaRange(1)) | (centreTheta>Opt.ThetaRange(2));
      Areas(idx) = 0;
    end
    logmsg(1,'  total %d triangles (%d orientations), %d transitions',size(idxTri,2),numel(fthe),nTransitions);
  end
  
  if (~AnisotropicIntensities), fInt = ones(size(fthe)); end
  if (~AnisotropicWidths), fWid = zeros(size(fthe)); end
  
  minBroadening = inf;
  nBroadenings = 0;
  sumBroadenings = 0;

  for iTrans = 1:nTransitions
    
    % Interpolation
    %------------------------------------------------------
    if (DoInterpolation)
      fPos = esintpol(Pdat(iTrans,:),InterpParams,Opt.nKnots(2),InterpMode{1},fphi,fthe);
      if (AnisotropicIntensities)
        fInt = esintpol(Idat(iTrans,:),InterpParams,Opt.nKnots(2),InterpMode{2},fphi,fthe);
      end
      if (AnisotropicWidths)
        fWid = esintpol(Wdat(iTrans,:),InterpParams,Opt.nKnots(2),InterpMode{3},fphi,fthe);
      end
    else
      fPos = Pdat(iTrans,:);
      if (AnisotropicIntensities), fInt = Idat(iTrans,:); end
      if (AnisotropicWidths), fWid = Wdat(iTrans,:); end
    end
    
    msg1 = '';
    if (~NonEquiPops) && any(fInt(:)<0)
      % Try to correct underswings due to (very) small numerical errors
      maxInt = max(fInt);
      fInt((fInt<0)&(fInt/maxInt>-1e-6)) = 0;
      if any(fInt(:)<0)
        msg1 = 'intensities';
      end
    end
    if any(fWid(:)<0), msg1 = 'widths'; end
    if ~isempty(msg1)
      error('Negative %s encountered! Please report!',msg1);
    end
    
    % Summation or projection
    %------------------------------------------------------
    if (DoProjection)
      if (Axial)
        thisspec = projectzones(fPos,fInt,fSegWeights,xAxis);
      else
        thisspec = projecttriangles(idxTri,Areas,fPos,fInt,xAxis);
      end
      % minBroadening = ?
    else
      if (Axial)
        fPosC = (fPos(1:end-1) + fPos(2:end))/2;
        fIntC = fSegWeights.*(fInt(1:end-1) + fInt(2:end))/2;
        fSpread = abs(fPos(1:end-1) - fPos(2:end));
        fWidM  = (fWid(1:end-1) + fWid(2:end))/2;
        c1 = 1.57246; c2 = 18.6348;
      else
        fPosSorted = sort(fPos(idxTri),1);
        fPosC = mean(fPosSorted,1);
        fIntC = Areas.*mean(fInt(idxTri),1);
        fSpread = fPosSorted(3,:) - fPosSorted(1,:);
        fWidM = mean(fWid(idxTri),1);
        c1 = 2.8269; c2 = 42.6843;
      end
      Lambda = fWidM./fSpread;
      gam = 1./sqrt(c1*Lambda.^2 + c2*Lambda.^4);
      fWidC = fWidM.*(1 + Opt.Smoothing*gam);

      thisspec = lisum1i(Template.y,Template.x,Template.lw,fPosC,fIntC,fWidC,xAxis);

      minBroadening = min(minBroadening,min(Lambda));
      sumBroadenings = sumBroadenings + sum(Lambda);
      nBroadenings = nBroadenings + numel(Lambda);
    end
    
    thisspec = thisspec*(2*pi); % powder integal over chi (0..2*pi)
    
    if (SummedOutput),
      spec = spec + thisspec;
    else
      spec(iTrans,:) = thisspec;
    end
    
  end % for iTrans

  if (~DoProjection)
    logmsg(1,'  Smoothness: overall %0.4g, worst %0.4g\n   (<0.5: probably bad, 0.5-3: ok, >3: overdone)',sumBroadenings/nBroadenings,minBroadening);
  end
  
end
%=======================================================================

else % if ~BruteForceSum else ...

  logmsg(1,'  no interpolation',nOrientations);
  logmsg(1,'  constructing stick spectrum');
  logmsg(1,'  summation over %d orientations',nOrientations);
  spec = zeros(1,Exp.nPoints);
  prefactor = (Exp.nPoints-1)/(Exp.Range(2)-Exp.Range(1));
  for k = 1:nOrientations
    p = round(1+prefactor*(Pdat{k}-Exp.Range(1)));
    OutOfRange = (p<1) | (p>Exp.nPoints);
    p(OutOfRange) = [];
    Idat{k}(OutOfRange) = [];
    if (AnisotropicIntensities)
      spec = spec + full(sparse(1,p,Weights(k)*Idat{k},1,Exp.nPoints));
    else
      spec = spec + full(sparse(1,p,Weights(k),1,Exp.nPoints));
    end
  end
  spec = spec/Exp.deltaX;

end
%=======================================================================





%=======================================================================
%                         Final activities
%=======================================================================
logmsg(1,'-final-------------------------------------------------');

% Convolution with line shape.
%-----------------------------------------------------------------------
logmsg(1,'  harmonic %d',Exp.Harmonic);
if (ConvWidth)
  lwG = Sys.lwEndor(1);
  lwL = Sys.lwEndor(2);

  % Add padding to left and right of spectral range
  % to reduce convolution artifacts
  nPad = 0;
  exceedsLowerLimit = any(spec(:,1)~=0);
  exceedsHigherLimit = any(spec(:,end)~=0);
  if exceedsLowerLimit
    if exceedsHigherLimit
      logmsg(0,'** Spectrum exceeds frequency range. Artifacts at lower and upper frequency limits possible.');
    else
      logmsg(0,'** Spectrum exceeds frequency range. Artifacts at lower frequency limit possible.');
    end
  else
    if exceedsHigherLimit
      logmsg(0,'** Spectrum exceeds frequency range. Artifacts at upper frequency limit possible.');
    end
  end
  if  exceedsLowerLimit || exceedsHigherLimit
    nPad = round(max([lwG lwL])/Exp.deltaX*Opt.PaddingMultiplier);
    spec = [repmat(spec(:,1),1,nPad) spec]; % left padding
    spec = [spec repmat(spec(:,end),1,nPad)]; % right padding
  end

  % Gaussian broadening
  Harmonic2Do = Exp.Harmonic;
  if (lwG>0)
    logmsg(1,'  convoluting with Gaussian, FWHM %g MHz, derivative %d',lwG,Harmonic2Do);
    if min(size(spec))==1, fwhm = [lwG 0]; else fwhm = [0 lwG]; end
    spec = convspec(spec,Exp.deltaX,fwhm,Harmonic2Do,1);
    Harmonic2Do = 0;
  end

  % Lorentzian broadening
  if (lwL>0)
    logmsg(1,'  convoluting with Lorentzian, FWHM %g MHz, derivative %d',lwL,Harmonic2Do);
    if min(size(spec))==1, fwhm = [lwL 0]; else fwhm = [0 lwL]; end
    spec = convspec(spec,Exp.deltaX,fwhm,Harmonic2Do,0);
    %Harmonic2Do = 0;
  end

  % Remove padding
  if (nPad>0)
    spec(:,1:nPad) = [];
    spec(:,Exp.nPoints+1:end) = [];
  end

else
  logmsg(1,'  no linewidth given: returning stick spectrum');
  
  if (Exp.Harmonic>0)
    logmsg(1,'  harmonic %d: using differentiation',Exp.Harmonic);
    for h = 1:Exp.Harmonic
      dspec = diff(spec,[],2)/Exp.deltaX;
      spec = (dspec(:,[1 1:end]) + dspec(:,[1:end end]))/2;
    end
  else
    logmsg(1,'  harmonic 0: returning absorption spectrum');
  end

end

% Assign output.
%-----------------------------------------------------------------------
switch (nargout)
  case 0,
    cla
    plot(xAxis,spec);
    axis tight
    xlabel('frequency (MHz)');
    ylabel('intensity (arb.u.)');
    if ~isnan(Exp.mwFreq)
      title(sprintf('ENDOR at %0.8g GHz and %0.8g mT',Exp.mwFreq,Exp.Field));
    else
      title(sprintf('ENDOR at %0.8g mT',Exp.Field));
    end
  case 1, varargout = {spec};
  case 2, varargout = {xAxis,spec};
  case 3, varargout = {xAxis,spec,Transitions};
end

% Report performance.
%-----------------------------------------------------------------------
[Hours,Minutes,Seconds] = elapsedtime(StartTime,clock);
msg = sprintf('cpu time %dh%dm%0.2fs',Hours,Minutes,Seconds);
logmsg(0.5,msg);

logmsg(1,'=end=salt=========%s=================\n',datestr(now));

clear global EasySpinLogLevel

return
