! This file is part of the ellc binary star model
! Copyright (C) 2016 Pierre Maxted
! 
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
! 
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
! 
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

module ellc
!
! Binary star light curve model.
!
! HISTORY
! -------
! 30 Nov 2017
!  Added Correia (2014A&A...570L...5C) star shape model.
!
! 5 May 2017
!  Added option to send limb darkening law as an array of specific intensities 
!  on a uniform grid of mu values. 
!  
! 14 Sep 2016
!  Improved definitions and handling of coordinates - picked up some bugs
!  p.maxted@keele.ac.uk
!
! 21 Jul 2016
!  Corrected bug in rv() - remove calculation for iobs=0
!  Corrected bug in calculation of simplified reflection
!  p.maxted@keele.ac.uk
!
! 24 May 2016
!  Added function rv() for faster calculation of radial velocities when called
!  from python function ellc.rv() with option flux_weight=False.
!  Corrected bug with initialization of star sizes/shapes in eccentric orbits
!  p.maxted@keele.ac.uk
!
! May 2016
!  Changed definition of third light to something more sensible
!  Avoided stop if root polishing step fails in ell_ell_intersect - return
!  with fluxes/rv = bad_dble and set (new) flag bit b_ellc_fail
!  p.maxted@keele.ac.uk
!
! Feb 2016
! Corrected bug with uninitialised variables for partial eclipses
! Added simplified reflection effect
! p.maxted@keele.ac.uk
!
! Jan 2016
! First version 
! p.maxted@keele.ac.uk
!

use constants
use utils
use ellipse
use gauss_legendre
use stellar
use spots

implicit none
public

! Bit flags for return status flags.
integer, parameter :: b_ellc_eclipse        = 0 ! There is an eclipse
integer, parameter :: b_ellc_star1_eclipsed = 1 ! Star 1 is eclipsed by star 2
integer, parameter :: b_ellc_star2_eclipsed = 2 ! Star 2 is eclipsed by star 1
integer, parameter :: b_ellc_total          = 3 ! Eclipse is total
integer, parameter :: b_ellc_transit        = 4 ! Eclipse is a transit
integer, parameter :: b_ellc_double_partial = 5 ! Eclipse is "double-partial"
integer, parameter :: b_ellc_warn_spot_1    =11 ! Warning for spots on star 1
integer, parameter :: b_ellc_warn_spot_2    =12 ! Warning for spots on star 2
integer, parameter :: b_ellc_fail           =14 ! Calculation failed
integer, parameter :: b_ellc_warning        =15 ! Warnings were raised
integer, parameter :: b_ellc_error          =16 ! Invalid input

contains

function lc(n_obs,                & ! Number of observations
            input_times,          & ! Array of times/phases 
            binary_pars,          & ! Parameters of the binary system
            control_integers,     & ! Control integers
            spots_1, spots_2,     & ! Spot data
            n_mugrid_1, mugrid_1, & ! Limb darkening array, star 1
            n_mugrid_2, mugrid_2, & ! Limb darkening array, star 2
            verbose)              & ! Verbosity of printed output
            result(flux_rv_flag)
implicit none
integer, intent(in)   :: n_obs
!f2py integer, intent(hide), depend(input_times) :: n_obs = len(input_times)
double precision, intent(in)  :: input_times(n_obs)
!f2py integer, parameter :: n_par = 39
double precision, intent(in)  :: binary_pars(n_par)
!f2py integer, parameter :: n_ipar = 10
integer, intent(in)   :: control_integers(n_ipar)
double precision, intent(in) :: spots_1(:,:), spots_2(:,:)
!f2py integer, intent(hide), depend(mugrid_1) :: n_mugrid_1 = len(mugrid_1)
integer, intent(in)   :: n_mugrid_1
double precision, intent(in)  :: mugrid_1(n_mugrid_1)
!f2py integer, intent(hide), depend(mugrid_2) :: n_mugrid_2 = len(mugrid_2)
integer, intent(in)   :: n_mugrid_2
double precision, intent(in)  :: mugrid_2(n_mugrid_2)
integer, intent(in)   :: verbose
double precision :: flux_rv_flag(n_obs,6)
!
! INPUT:
! n_obs is number of observations.
! Input_times must be in days for light-time effect to be calculated correctly.
!
! Properties of the binary star are specified by the elements of
! binary_pars, as follows
!
! (1)  = T_0, apparent time of mid-eclipse for star 1 by star 2.
! (2)  = Anomalistic period (days or =1 for phased data).
! (3)  = Surface brightness ratio, S_2/S_1
! (4)  = Fractional radius of star 1, R_1/a
! (5)  = Fractional radius of star 2, R_2/a
! (6)  = Orbital inclination at time T_0 [degrees]
! (7)  = Third light contribution relative to apparent total flux at
!        time T_0 excluding eclipse effects.
! (8)  = Semi-major axis, a, in solar radii for calculation of 
!        light travel time, radial velocities and Doppler boosting.
!        (<= 0.0 to ignore)
! (9)  = sqrt(e).cos(omega) at time T_0
! (10) = sqrt(e).sin(omega) at time T_0
! (11) = Mass ratio m_2/m_1
! (12-15) = Limb darkening coefficients for star 1.
! (16-19) = Limb darkening coefficients for star 2
! (20) = Gravity darkening exponent for star 1 
! (21) = Gravity darkening exponent for star 2   
! (22) = Rate of change of inclination [degrees/anomalistic period]
! (23) = Apsidal motion rate  [degrees/siderial period]
! (24) = Asynchronous rotation factor for star 1, F_1
! (25) = Asynchronous rotation factor for star 2, F_2
! (26) = Doppler boosting factor, star 1 (=0.0 to ignore)
! (27) = Doppler boosting factor, star 2 (=0.0 to ignore)
! (28) = Heating+reflection coefficient of star 1
! (29) = Heating+reflection exponent, star 1.
! (30) = Heating+reflection linear limb darkening coefficient, star 1
! (31) = Heating+reflection coefficient of star 2
! (32) = Heating+reflection exponent, star 2.
! (33) = Heating+reflection linear limb darkening coefficient, star 2
! (34) = Sky-projected angle between orbital and rotation axes, star 1 [degrees]
! (35) = Sky-projected angle between orbital and rotation axes, star 2 [degrees]
! (36) = V_rot.sini for calculation of R-M effect for star 1 [km/s] - see notes
! (37) = V_rot.sini for calculation of R-M effect for star 2 [km/s] - see notes
! (38) = Fluid second Love number for radial displacement, h_f, star 1
! (39) = Fluid second Love number for radial displacement, h_f, star 1
!
! Calculation of the light curve is controlled by the elements of
! control_integers as follows
! (1)  = Grid size for numerical integration of fluxes, star 1
! (2)  = Grid size for numerical integration of fluxes, star 2
! (3)  = Number of spots on star 1 - see notes below
! (4)  = Number of spots on star 2 - see notes below
! (5)  = Limb darkening law for star 1 (see module stellar)
! (6)  = Limb darkening law for star 2 (see module stellar)
! (7)  = Model for shape of star 1 (see module stellar)
! (8)  = Model for shape of star 2 (see module stellar)
! (9)  = 0 to disable calculation of flux-weighted radial velocities
! (10) = Gravity darkening calculation - see notes below.
!
! Stellar radii
! -------------
!  The radius of a star is specified as the radius of a sphere with the same
!  volume as the ellipsoid that approximates the size and shape of the star
!  in the model (see module stellar). For stars defined by the Roche potential
!  only, the radius can be set =1 to select a star that fills its Roche lobe
!  (or its equivalent in the case of non-synchronous rotation).
!
! Output
! ------
!
! The results are returned in the array flux_rv_flag as follows.
! (1:n_obs,1) = Light curve
! (1:n_obs,2) = Flux of star 1
! (1:n_obs,3) = Flux of star 2
! (1:n_obs,4) = Radial velocity of star 1 [km/s] 
! (1:n_obs,5) = Radial velocity of star 2 [km/s] 
! (1:n_obs,6) = Flags
! 
! To test the bit flags b_ellc_... listed at the top of this module use
!  btest(int(flux_rv_flag(:,6)),<bit flag name>)
!
! Radial velocities are only calculated if semi-major axis is specified
! and period is not equal to 1. If control_integers(9) == 0 then these
! are centre-of-mass radial velocities, otherwise the flux-weighted radial
! velocities are calculated. 
! 
! For all times/phases where the input parameters are invalid the elements
! flux_rv_flag(:,1:5) are returned as bad_dble
!
! Light travel time
! -----------------
!  If the semi-major axis is > 0 then the effect of the light travel time 
!  across the orbit is included in the calculation of the star's positions. In
!  this case the parameter T_0 is the apparent time of primary eclipse, i.e.,
!  T_0 refers to the time of mid-eclipse (inferior conjunction)
!
! Heating and reflection
! ----------------------
!   Heating and reflection can be dealt with using either a detailed calculation
!  or a simplified analytical model.
!   For the detailed calculation, the brightness of each point on the stellar
!  surface that receives an irradiating flux is increased by an amount
!  F_0*H_0*(1/d_c**2)**H_1*(1-u_H*(1.d0-mu)), where
!   F_0 = flux from companion
!   d_c = distance from point on surface to companion
!   mu  = cos(viewing angle)
!  
!  The sharp edge of the irradiated region produces numerical noise in the
!  resulting lightcurve. This can be avoided using a simplified treatment of
!  reflection in which the flux from each star is modulated by an additional
!  term
!    H_0*F_0*r_c**2 * [(0.5+0.5*(sini*cos(theta))**2) + sini*cos(theta)],
!    where
!    F_0 = flux from companion
!    r_c = companion radius/separation
!    i   = inclination
!    theta = phase angle
!  To select simplified reflection set H_1 <= 0
!  Reflected light is eclipsed in proportion to the eclipsed fraction of the
!  light from each star.
!  Doppler boosting is not applied to reflected light.
!  sin^i factor not varied for di/dt.
!
!  To remove any calculation of reflection/heating set H_0 <= 0.
!  
! Rotation
! --------
!  The asynchronous rotation factors F_1 and F_2 are used to calculate the
! shapes of the stars (unless spherical stars are specified).
!  If V_rot.sini is 0 then F_1 or F_2 is used to calculate the projected 
! equatorial rotation velocity of star 1 or star 2, respectively, for the
! calculation of the flux-weighted radial velocity. Otherwise, the
! flux-weighted radial velocity of the star is calculated using the specified 
! value of V_rot.sini. 
!  Note that F_1 and F_2 are relative to the actual synchronous rotation rate
! (rotation period = orbital period) not pseudo-synchronous rotation rate.
!
! Star spots
! ----------
! spots_1(:,i) are the parameters for spot i on star 1.
! spots_2(:,i) are the parameters for spot i on star 2.
! The number of spots on each stars are given by control_integers(3:4).
! This can be less than the acual sizes of the arrays spots_1 and spots_2.
!
! See module file spots.f90 for the parameter definitions of a single spot
!  The effect of the spot on the light curve is calculated using the algorithm
! by Eker (1994ApJ...420..373E, 1994ApJ...430..438E) for circular spots on a
! spherical star with quadratic limb darkening. If the limb-darkening law used
! for the main calculation is not linear or quadratic then the coefficients of
! the limb-darkening law used for the calculation of the effects of the spots
! are set so that the intensity distribution matches at mu = 0, 0.5 and 1.
!
! ** N.B. ** The effect of each spot on the light curve is additive so
! overlapping spots can result in non-physical negative fluxes for some
! regions of the star.
!
! Limb darkening
! --------------
!   Limb darkening can be described either using one of the parametric forms
!   described in the module stellar, or as a tabulated grid of specific 
!   intensities. In the latter case, the limb darkening coefficients in 
!   binary_pars are not used. Instead, the specific intensity is determined by
!   linear interpolation between the values in the arrays mugrid_1 and 
!   mugrid_2. These are assumed to contain specific intensies on a uniform grid
!   of mu values from 0 (first element) to 1 (last element).
!   The tabulated limb darkening option is selected by setting the appropriate
!   value of control_integers to the value of ld_mugrid specified in the 
!   module constants. 
!   N.B. the arrays of specific intensies are assumed to be normalised, e.g., 
!   mugrid_1(n_mugrid_1) = 1, but this is not checked. 
!
! Volume calculation
! ------------------
!  In eccentric orbits, the volume of the star is assumed to be constant. In
!  general, the volume is calculated from the volume of the approximating
!  ellipsoid. In the case of synchronous rotation, the volume of the star can be
!  calculated using equation (2.18) from Kopal "Dynamics of Close Binary 
!  Systems" (Springer, 1978) by selecting the star model starshape_roche_v
!
! 
! Local variables
double precision :: radius1, radius2, sep, frot1, frot2,rlimit1,rlimit2
double precision :: qmass1,qmass2,flux01,flux02,incl_0,hf1,hf2,spar1,spar2
double precision :: ecc, omega_0
double precision :: abcd1(4),abcd2(4)
double precision, allocatable :: phi_rot_1(:), phi_rot_2(:)
double precision, allocatable ::  df_1(:,:), df_2(:,:)
double precision :: sbratio_0,anorm1,anorm2,eclipsed_area
!f2py integer, parameter :: n_ell_par = 14
double precision :: ellipse_1(n_ell_par),ellipse_2(n_ell_par)
double precision :: circle_1(n_ell_par),circle_2(n_ell_par)
integer, parameter :: nfpar=32
double precision, allocatable :: fpar1(:), fpar2(:)
integer :: nfpar1, nfpar2
double precision :: efac, phi_1, phi_2, spot_flux_1, spot_flux_2
double precision :: spot_ecl_flux_1, spot_ecl_flux_2
double precision :: spot_ecl_rv_1, spot_ecl_rv_2
double precision :: tperi0,p_anom,p_anom_s,incl,time,time_0,omdot
double precision :: mm,ee,r,r_1,r_2,cosi,sini,vsini1,vsini2,sini_0
double precision :: refl_1, refl_2, rfac_1, rfac_2, heat,heat2, l_3
double precision :: true_anomaly,cosnu,sinnu, dltte,sbfac_1,sbfac_2
double precision :: omega_1,true_anomaly_1,cosnu_1,sinnu_1,sinom1,cosom1
double precision :: omega_2,true_anomaly_2,cosnu_2,sinnu_2,sinom2,cosom2
double precision :: u1,v1,w1,u2,v2,w2,qfac1, qfac2,didt, wt,ecl_rv_1,ecl_rv_2
double precision :: uapp1,vapp1,uapp2,vapp2,a,spot_rv_1,spot_rv_2
double precision :: flux_1,flux_2,flux_3,rv1,rv2,vorb1,vorb2,rvflux_1,rvflux_2
double precision :: t1,t2,alite1,alite2,ecl_flux_1,ecl_flux_2,area_flags(2)
double precision :: avflux,fnorm, df, frac(2)
double precision :: ellipse_t(n_ell_par), xy_tng(2,2),ellipse_s(n_ell_par)
double precision :: lat_i, lon_i, lat_j, lon_j, gam_i, gam_j, fac_i, df1, df2
double precision :: qldc_1(2), qldc_2(2), tr(2,3), p_sid, phirot,r_spot
double precision :: ecl_area_tol
double precision :: u_s, v_s, w_s, alpha_s, beta_s, gamma_s ! Spot coords/size
logical :: dorv,dolite,dorvflux,large,sphere_1,sphere_2,exact_grav
logical :: ell_ell_fail
integer :: imodel1,imodel2, i_spot_calc, n_spot_calc,ldlaw_1,ldlaw_2
integer :: n_spot_1,n_spot_2,i_spot, j_spot, ifail, ii, verbose1, iiswitch
integer :: ngx1,ngx2,iobs,return_flags, return_flags_init, overlap, eclipse_type
integer, allocatable :: ii_1(:,:), ii_2(:,:)
double precision, parameter :: c_kms = iau_c*1.0d-3 ! Speed of light in km/s
! Fractional tolerance for radius calculations in function starshape()
double precision, parameter :: rtol = 1.0d-6
! Limits on beta_s for calculation of occulted spot area (radians).
double precision, parameter :: beta_s_lim = 1.0d-2
! Fraction limit on areas to avoid trying to calculate integrals on very small
! ellipse intersections
double precision, parameter :: atol = 1.0d-5

! Start

verbose1 = verbose_for_calls(verbose)
return_flags_init = 0 
frac(1:2) = 0
rv1 = not_set_dble
rv2 = not_set_dble
refl_1 = 0
refl_2 = 0
rfac_1 = 0
rfac_2 = 0

if (verbose >= v_user) then
  print *,'Start ellc:lc'
  print *,'N_obs  = ',n_obs
  print *,'t_obs(1)  = ',input_times(1)
  print *,'t_obs(N_obs)  = ',input_times(n_obs)
endif

! Some useful variables
time_0 = binary_pars(1)
p_anom = binary_pars(2)
p_anom_s = p_anom*86400.0d0
ecc = binary_pars(9)**2 + binary_pars(10)**2 
efac = sqrt((1.0d0+ecc)/(1.0d0-ecc))
if (ecc == 0.0d0) then
  omega_0 = 0.0d0
else
  omega_0 = atan2(binary_pars(10),binary_pars(9))
endif
incl_0 = binary_pars(6)*dtor
if (verbose >= v_user) then
  print *,'ellc: time_0 = ',time_0
  print *,'ellc: p_anom = ',p_anom
  print *,'ellc: e = ',real(ecc),'; omega_0 = ',omega_0,' radians'
endif
sini_0 = sin(incl_0) 
a = binary_pars(8)
radius1 = binary_pars(4)
radius2 = binary_pars(5) 
l_3 = binary_pars(7)
qmass1 = binary_pars(11) ! Mass of companion to star 1 w.r.t. m_1
qmass2 = 1.0d0/qmass1    ! Mass of companion to star 2 w.r.t. m_2
qfac2 = 1.0d0/(1.0d0+qmass1)
qfac1 = qmass1*qfac2
omdot = binary_pars(23)*dtor
p_sid = p_anom*(1.0d0 - omdot/twopi)  ! Siderial period
if ((omdot /= 0.0d0).and.(verbose >= v_user)) then
  print *,'ellc: omdot = ',omdot,' radians/(siderial period)'
  print *,'ellc: p_sid = ',p_sid
endif

imodel1 = control_integers(7)
imodel2 = control_integers(8)
sphere_1 =  (imodel1 == starshape_sphere)
sphere_2 =  (imodel2 == starshape_sphere)
if (imodel1 == starshape_love) then
  frot1 = 1
  hf1 = binary_pars(38)
  if ((hf1 < 0.).or.(hf1 > 5/2.)) then
    if (verbose > v_silent) then
      print *,'End ELLC - invalid value for h_f,1'
      print *,'h_f,1 = ',hf1
    endif
    return
  endif
  spar1 = hf1
  if (verbose >= v_user) then
    print *,'h_f,1 =',hf1
  endif
else
  frot1 = binary_pars(24)
  spar1 = frot1
  if (verbose >= v_user) then
    print *,'F_rot,1 =',frot1
  endif
endif

if (imodel2 == starshape_love) then
  frot2 = 1
  hf2 = binary_pars(39)
  if ((hf2 < 0.).or.(hf2 > 5/2.)) then
    if (verbose > v_silent) then
      print *,'End ELLC - invalid value for h_f,2'
      print *,'h_f,2 = ',hf2
    endif
    return
  endif
  spar2 = hf2
  if (verbose >= v_user) then
    print *,'h_f,2 =',hf2
  endif
else
  frot2 = binary_pars(25)
  spar2 = frot2
  if (verbose >= v_user) then
    print *,'F_rot,2 =',frot2
  endif
endif

if (verbose >= v_user) then
  print *,'Star 1, (H_0, H_1, u_H) = ', real(binary_pars(28:30))
  print *,'Star 2, (H_0, H_1, u_H) = ', real(binary_pars(31:33))
endif
ngx1 = control_integers(1)
ngx2 = control_integers(2)
if (verbose >= v_user) then
  print *,'Star 1: n_grid, shape = ',ngx1,starshape_name(imodel1)
  print *,'Star 2: n_grid, shape = ',ngx2,starshape_name(imodel2)
endif
n_spot_1 = control_integers(3)
n_spot_2 = control_integers(4)
ldlaw_1 = control_integers(5)
if (ldlaw_1 ==  ld_mugrid) then
  nfpar1 = nfpar + n_mugrid_1
  allocate(fpar1(nfpar1))
  ldlaw_1 = -n_mugrid_1
  fpar1(nfpar+1:nfpar1) = mugrid_1
  if (verbose >= v_user) then
    print *,'n_mugrid_1 = ',n_mugrid_1
    print *,'mugrid_1 = ',mugrid_1(1),' .. ',mugrid_1(n_mugrid_1)
  endif
else
  nfpar1 = nfpar
  allocate(fpar1(nfpar))
endif

ldlaw_2 = control_integers(6)
if (ldlaw_2 ==  ld_mugrid) then
  nfpar2 = nfpar + n_mugrid_2
  allocate(fpar2(nfpar2))
  ldlaw_2 = -n_mugrid_2
  fpar2(nfpar+1:nfpar2) = mugrid_2
  if (verbose >= v_user) then
    print *,'n_mugrid_2 = ',n_mugrid_2
    print *,'mugrid_2 = ',mugrid_2(1),' .. ',mugrid_2(n_mugrid_2)
  endif
else
  nfpar2 = nfpar
  allocate(fpar2(nfpar))
endif

didt = binary_pars(22)*dtor
! vorb1 = K1/sini, vorb2=K2/sini
vorb1 = 0
vorb2 = 0
alite1 = 0
alite2 = 0
dorv = .false.
dolite = .false.
! Semi-major axis in units of light-days
if (binary_pars(8) >  0.0d0) then
  alite1 = binary_pars(8)*qfac1 * solar_radius/iau_c/8.64d4
  alite2 = binary_pars(8)*qfac2 * solar_radius/iau_c/8.64d4
  ! Correction to T_0 for light travel time - see Borkovits et al., 
  !   2015MNRAS.448..946B, equation (25)
  dltte = alite2*sini_0*(qmass1-1.0d0)/(qmass1+1.0d0) & 
        * (1-ecc**2)/(1+ecc*sin(omega_0))
  time_0 = time_0 - dltte
  if (verbose >= v_user) then
    print *,'Light travel time correction to T_0 = ', real(dltte)
  endif


  dolite = .true.
! To test if a variable is set to 1, test against epsilon(0.) to avoid
! issues with user initialising using single-precision values.
  if (abs(p_anom-1.0d0) <  epsilon(0.)) then
    if (verbose >= v_warn) then
      print *,' WARNING: Semi-major axis given but period=1 (phased data?).'
      print *,' Radial velocity and Doppler boosting will NOT by calculated.'
    endif
    return_flags_init = ibset(return_flags_init,b_ellc_warning)
  else
    dorv = .true.
    vorb1 = a*qfac1/(solar_asini_kms_d*p_anom*sqrt(1-ecc**2))
    vorb2 = qmass2*vorb1

    if (verbose >= v_user) then
      print *,'K_1 = ',real(vorb1*sini_0),' km/s.'
      print *,'K_2 = ',real(vorb2*sini_0),' km/s.'
    endif
  endif
endif

! Check radii against roche lobe limits.
rlimit1 = roche_l1(qmass1,frot1)*(1.0d0-ecc)
if (radius1 == 1) then
  if (ecc > 0) then
    return_flags_init = ibset(return_flags_init,b_ellc_warning)
    if (verbose >= v_warn) then
      print *,'ellc: WARNING Star 1 set at limiting radius in eccentric binary'
      print *,'Radius will vary from = ',rlimit1*(1-ecc),' to ',rlimit1*(1+ecc)
    endif
  else
    if (verbose >= v_user) then
      print *,'Star 1 radius set at limit = ',rlimit1
    endif
  endif
else
  if (radius1 > rlimit1) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - star 1 exceeds limiting radius'
      print *,'radius1 = ',radius1
      print *,'rlimit1 = ',rlimit1
      print *,'q = m_2/m_1 = ',qmass1
      print *,'F_1 = ',frot1
      print *,'e = ',ecc
    endif
    return
  else
    if (verbose >= v_user) then
      print *,'Star 1 limiting radius= ',real(rlimit1)
    endif
  endif
endif
rlimit2 = roche_l1(qmass2,frot2)*(1.0d0-ecc)
if (radius2 == 1) then
  if (ecc > 0) then
    return_flags_init = ibset(return_flags_init,b_ellc_warning)
    if (verbose >= v_warn) then
      print *,'ellc: WARNING Star 2 set at limiting radius in eccentric binary'
      print *,'Radius will vary from = ',rlimit2*(1-ecc),' to ',rlimit2*(1+ecc)
    endif
  else
    if (verbose >= v_user) then
      print *,'Star 2 radius set at limit = ',real(rlimit2)
    endif
  endif
else
  if (radius2 > rlimit2) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - star 2 exceeds limiting radius'
      print *,'radius2 = ',radius2
      print *,'rlimit2 = ',rlimit2
      print *,'q = m_1/m_2 = ',qmass2
      print *,'F_2 = ',frot2
      print *,'e = ',ecc
    endif
    return
  else
    if (verbose >= v_user) then
      print *,'Star 2 limiting radius= ',real(rlimit2)
    endif
  endif
endif

dorvflux = (control_integers(9) /= 0).and.dorv

exact_grav = (control_integers(10) /= 0)

if (((imodel1 == starshape_roche_v).and.(frot1/=1.0d0)) .or. &
    ((imodel2 == starshape_roche_v).and.(frot2/=1.0d0)) ) then
  flux_rv_flag(1:n_obs,1:5) = bad_dble
  return_flags_init = ibset(return_flags_init,b_ellc_error)
  flux_rv_flag(1:n_obs,6) = return_flags_init
  if (verbose > v_silent) then
    print *,'End ELLC - roche_vol not enabled for non-synchronous rotation'
    print *,'F_rot,1 = ',frot1
    print *,'Shape_1 = ',starshape_name(imodel1)
    print *,'F_rot,2 = ',frot2
    print *,'Shape_2 = ',starshape_name(imodel2)
  endif
  return
endif

! Star spots
if (n_spot_1 > 0) then
  if (verbose >= v_user) then
    print *,'n_spot_1 = ',n_spot_1
  endif
  if (n_spot_1 > size(spots_1,2)) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - size(spots_1,2) < n_spot_1'
      print *,'size(spots_2),nspot_1 = ',size(spots_1,2),n_spot_1
    endif
    return
  endif
  if (size(spots_1,1) /= n_spot_par) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - spots_1 array wrong size'
      print *,'size(spots_1) = ',size(spots_1,1),size(spots_1,2)
    endif
    return
  endif

  if (ldlaw_1 < -1) then
    qldc_1(:) =  ld_quad_match(ldlaw_1, mugrid_1)
  else
    qldc_1(:) =  ld_quad_match(ldlaw_1, binary_pars(12:15))
  endif
  if (verbose >= v_user) then
    print *,'qldc_1 = ',qldc_1
  endif
  do i_spot = 2, n_spot_1
    lat_i = spots_1(i_spot_lat,i_spot)*dtor
    lon_i = spots_1(i_spot_lon,i_spot)*dtor
    gam_i = spots_1(i_spot_gam,i_spot)*dtor
    do j_spot = 1,i_spot-1
      lat_j = spots_1(i_spot_lat,j_spot)*dtor
      lon_j = spots_1(i_spot_lon,j_spot)*dtor
      gam_j = spots_1(i_spot_gam,j_spot)*dtor
      if(angular_distance(lon_i, lat_i, lon_j, lat_j) < (gam_i+gam_j)) then
        return_flags_init = ibset(return_flags_init,b_ellc_warning)
        if (verbose >= v_warn) then
          print *,'ellc: WARNING spots on star 1 overlap: ',i_spot,j_spot
        endif
      endif
    end do
  end do
endif

if (n_spot_2 > 0) then
  if (verbose >= v_user) then
    print *,'n_spot_2 = ',n_spot_2
  endif
  if (n_spot_2 > size(spots_2,2)) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - size(spots_2,2) < n_spot_2'
      print *,'size(spots_2),nspot_2 = ',size(spots_2,2),n_spot_2
    endif
    return
  endif
  if (size(spots_2,1) /= n_spot_par) then
    flux_rv_flag(1:n_obs,1:5) = bad_dble
    return_flags_init = ibset(return_flags_init,b_ellc_error)
    flux_rv_flag(1:n_obs,6) = return_flags_init
    if (verbose > v_silent) then
      print *,'End ELLC - input spots_2 array wrong size'
      print *,'size(spots_2) = ',size(spots_2,1),size(spots_2,2)
    endif
    return
  endif
  if (ldlaw_2 < -1) then
    qldc_2(:) =  ld_quad_match(ldlaw_2, mugrid_2)
  else
    qldc_2(:) =  ld_quad_match(ldlaw_2, binary_pars(16:19))
  endif
  if (verbose >= v_user) then
    print *,'qldc_2 = ',qldc_2
  endif
  do i_spot = 2, n_spot_2
    lat_i = spots_2(i_spot_lat,i_spot)*dtor
    lon_i = spots_2(i_spot_lon,i_spot)*dtor
    gam_i = spots_2(i_spot_gam,i_spot)*dtor
    do j_spot = 1,i_spot-1
      lat_j = spots_2(i_spot_lat,j_spot)*dtor
      lon_j = spots_2(i_spot_lon,j_spot)*dtor
      gam_j = spots_2(i_spot_gam,j_spot)*dtor
      if(angular_distance(lon_i, lat_i, lon_j, lat_j) < (gam_i+gam_j)) then
        return_flags_init = ibset(return_flags_init,b_ellc_warning)
        if (verbose >= v_warn) then
          print *,'ellc: WARNING spots on star 2 overlap: ',i_spot,j_spot
        endif
      endif
    end do
  end do
endif

if ((n_spot_1+n_spot_2) > 0) then 

  if (verbose >= v_debug) print *,'ellc: n_spot_1,2 = ',n_spot_1,n_spot_2
  allocate(phi_rot_1(n_obs))
  allocate(phi_rot_2(n_obs))
  allocate(df_1(n_obs, n_spot_1))
  allocate(df_2(n_obs, n_spot_2))
  allocate(ii_1(n_obs, n_spot_1))
  allocate(ii_2(n_obs, n_spot_2))

  if (didt /= 0 ) then
    return_flags_init = ibset(return_flags_init,b_ellc_warning)
    if (verbose >= v_warn) then
      print *,'ellc: WARNING di/dt not implemented for spots '
    endif
  endif

  do i_spot = 1, n_spot_1
    lat_i = spots_1(i_spot_lat,i_spot)*dtor
    lon_i = spots_1(i_spot_lon,i_spot)*dtor
    gam_i = spots_1(i_spot_gam,i_spot)*dtor
    fac_i = spots_1(i_spot_fac,i_spot)
    if (verbose >= v_user) then
      print '(a,I4,3f10.4)',' ellc: spot on star 1',i_spot,lat_i,lon_i,gam_i
    endif
    phi_rot_1(:) = twopi*(input_times(:)-time_0)/p_anom*frot1
    call eker(lon_i,lat_i,incl_0,gam_i,fac_i,qldc_1(1),qldc_1(2),phi_rot_1, &
              n_obs,df_1(:,i_spot),ii_1(:,i_spot), ifail)
    if (ifail /= 0) then
      if (verbose > v_silent) then
        print *,'ellc: Error calling eker for spot on star 1, ifail = ',ifail
      endif
      flux_rv_flag(1:n_obs,1:5) = bad_dble
      return_flags_init = ibset(return_flags_init,b_ellc_error)
      flux_rv_flag(1:n_obs,6) = return_flags_init
      return
    endif
  end do

  do i_spot = 1, n_spot_2
    lat_i = spots_2(i_spot_lat,i_spot)*dtor
    lon_i = spots_2(i_spot_lon,i_spot)*dtor + pi
    gam_i = spots_2(i_spot_gam,i_spot)*dtor
    fac_i = spots_2(i_spot_fac,i_spot)
    if (verbose >= v_user) then
      print '(a,I4,3f10.4)',' ellc: spot on star 2',i_spot,lat_i,lon_i,gam_i
    endif
    phi_rot_2(:) = twopi*(input_times(:)-time_0)/p_anom*frot2
    call eker(lon_i,lat_i,incl_0,gam_i,fac_i,qldc_2(1),qldc_2(2),phi_rot_2, &
              n_obs,df_2(:,i_spot),ii_2(:,i_spot), ifail)
    if (ifail /= 0) then
      if (verbose > v_silent) then
        print *,'ellc: Error calling eker for spot on star 2, ifail = ',ifail
      endif
      flux_rv_flag(1:n_obs,1:5) = bad_dble
      return_flags_init = ibset(return_flags_init,b_ellc_error)
      flux_rv_flag(1:n_obs,6) = return_flags_init
      return
    endif
  end do

endif

! Time of periastron passage prior to time_0 via eccentric anomaly
tperi0 = t_ecl_to_peri(time_0, ecc, omega_0, incl_0, p_sid, verbose)
if (verbose >= v_user) print *,'Reference time of periastron = ', real(tperi0)

! Calculate star shapes at time T_0.
if (verbose.ge.v_user) print *,'Star shapes at time/phase = ', real(time_0)
mm = twopi*mod(1.0d0+mod((time_0-tperi0)/p_anom,1.0d0),1.0d0)
ee = eanom(mm,ecc)
r = 1.0d0 - ecc*cos(ee)
abcd1 = starshape(radius1, r, spar1, ecc, qmass1, imodel1, rtol, verbose1)
if(abcd1(1) == bad_dble) then
 flux_rv_flag(1:n_obs,1:5) = bad_dble
 return_flags_init = ibset(return_flags_init,b_ellc_error)
 flux_rv_flag(1:n_obs,6) = return_flags_init
 if (verbose > v_silent) print *,'End ELLC - error calling starshape'
 return
endif
if (verbose >= v_user) print '(A,4F9.5)',' starshape: A1,B1,C1,D1 = ',abcd1

abcd2 = starshape(radius2, r, spar2, ecc, qmass2, imodel2, rtol, verbose1)
if(abcd2(1) == bad_dble) then
 flux_rv_flag(1:n_obs,1:5) = bad_dble
 return_flags_init = ibset(return_flags_init,b_ellc_error)
 flux_rv_flag(1:n_obs,6) = return_flags_init
 if (verbose > v_silent) print *,'End ELLC - error calling starshape'
 return
endif
if (verbose >= v_user) print '(A,4F9.5)',' starshape: A2,B2,C2,D2 = ',abcd2

! Rotation
if (dorv) then
  if (binary_pars(36) == 0.0d0) then
    vsini1 = frot1*twopi*abcd1(2)*a*solar_radius/1d3/(p_anom*8.64d4)*sini_0
  else
    vsini1 = binary_pars(36)
  endif 
  if (binary_pars(37) == 0.0d0) then
    vsini2 = frot2*twopi*abcd2(2)*a*solar_radius/1d3/(p_anom*8.64d4)*sini_0
  else
    vsini2 = binary_pars(37)
  endif 
  if (verbose >= v_user) then
    print *,'V_rot,1.sini = ',real(vsini1),' km/s.'
    print *,'V_rot,2.sini = ',real(vsini2),' km/s.'
  endif
else
  vsini1 = 0.0d0
  vsini2 = 0.0d0
endif

! Project ellipsoids onto sky for an observer viewing the stars face-on.
! For spherical stars, projecting the sphere causes numerical issues because
! the orientation of the axes is undefined, so calculate this case directly and
! save the result for later use.
if (sphere_1) then
  ellipse_1 = ell_init_from_par([radius1,radius1,0.0d0,0.0d0,0.0d0])
  circle_1(:) = ellipse_1(:)
else
  ellipse_1 =  ell_project_ellipsoid(abcd1(1:3),phi=0.0d0,incl=halfpi)
endif
if (sphere_2) then
  ellipse_2 = ell_init_from_par([radius2,radius2,0.0d0,0.0d0,0.0d0])
  circle_2(:) = ellipse_2(:)
else
  ellipse_2 =  ell_project_ellipsoid(abcd2(1:3),phi=0.0d0,incl=halfpi)
endif
if (verbose >= v_debug) then
  print *,' Ellipses for initialisation [a_p, b_p, x_c, y_c, phi]'
  print *,'ellipse_1 = ',real(ellipse_1(i_ell_ellpar))
  print *,'ellipse_2 = ',real(ellipse_2(i_ell_ellpar))
endif

! Setup parameters to be passed to bright() - ignoring heating for this step
fpar1(1) = 1.0d0
fpar1(2:5) = abcd1(1:4)
fpar1(6) = halfpi ! incl
fpar1(7) = 0.0d0 ! phi
fpar1(8) = r
fpar1(9) = ldlaw_1
fpar1(10:13) = binary_pars(12:15)  ! Limb darkening coeffs
if (exact_grav) then
  fpar1(14) = qmass1
  fpar1(15) = droche(qmass1,x=0.0d0,y=0.0d0,z=abcd1(3),d=r,f=frot1)
  fpar1(16) = frot1
  fpar1(27) = roche(abcd1(1)+abcd1(4),0.0d0,0.0d0,q=qmass1,d=r,f=frot1)
else
  fpar1(14:16) = gmodel_coeffs(abcd1, r, frot1, qmass1,  verbose1)
  fpar1(27) = 0 ! .not.exact_grav
endif
fpar1(17) = binary_pars(20) ! Gravity darkening coefficient, star 1
fpar1(18:22) =0.0d0 ! Heating/reflection model parameters
fpar1(23) = binary_pars(34)*dtor ! lambda_1
fpar1(24) = vsini1 ! V_rot,sini
fpar1(25) = binary_pars(26)  ! kboost
fpar1(26) = 0.0d0    ! rvflag
fpar1(28:31) =0.0d0 ! Coordinate transformation
fpar1(32) = 0  ! Disable coordinate transformation

! Integrating unitfunc (=1) gives the area of an ellipse calcuated by
! numerical integration. This can be compared to the real area of an 
! ellipse to get a correction factor (anorm1, anorm2). This is a function
! of the integration grid size and shape only, so these factors only need
! to be calculated once.
anorm1 = ellgauss(ellipse_1(i_ell_a_p),ellipse_1(i_ell_b_p),ngx1,unitfunc, &
                  nfpar1,fpar1,verbose1)
flux01 = ellgauss(ellipse_1(i_ell_a_p),ellipse_1(i_ell_b_p),ngx1,bright, &
                  nfpar1,fpar1,verbose1)
sbfac_1 = flux01/anorm1
anorm1 = anorm1/ellipse_1(i_ell_area)
flux01 = flux01/anorm1
if (verbose >= v_user) then
  print *,'anorm1 = ',real(anorm1)
  print *,'flux_0,1 = ',real(flux01)
  print *,'S_0,1 = ',real(sbfac_1)
endif

fpar2(1) = 1.0d0
fpar2(2:5) = abcd2(1:4)
fpar2(6) = halfpi! incl
fpar2(7) = 0.0d0 ! phi
fpar2(8) = r
fpar2(9) = ldlaw_2
fpar2(10:13) = binary_pars(16:19)  ! Limb darkening coeffs
if (exact_grav) then
  fpar2(14) = qmass2
  fpar2(15) = droche(qmass2,x=0.0d0,y=0.0d0,z=abcd2(3),d=r,f=frot2)
  fpar2(16) = frot2
  fpar2(27) = roche(abcd2(1)+abcd2(4),0.0d0,0.0d0, q=qmass2,d=r,f=frot2)
else
  fpar2(14:16) = gmodel_coeffs(abcd2, r, frot2, qmass2,  verbose1)
  fpar2(27) = 0 ! .not.exact_grav
endif
fpar2(17) = binary_pars(21) ! Gravity darkening coefficient, star 2
fpar2(18:22) =0.0d0 ! Heating/reflection model parameters
fpar2(23) = binary_pars(35)*dtor ! lambda_2
fpar2(24) = vsini2 ! V_rot,sini
fpar2(25) = binary_pars(27)  ! kboost
fpar2(26) =0.0d0    ! rvflag
fpar2(28:31) =0.0d0 ! Coordinate transformation
fpar2(32) = 0  ! Disable coordinate transformation

anorm2 = ellgauss(ellipse_2(i_ell_a_p),ellipse_2(i_ell_b_p),ngx2,unitfunc, &
                  nfpar2,fpar2,verbose1)
flux02 = ellgauss(ellipse_2(i_ell_a_p),ellipse_2(i_ell_b_p),ngx2,bright, &
                  nfpar2,fpar2,verbose1)
sbfac_2 = flux02/anorm2
anorm2 = anorm2/ellipse_2(i_ell_area)
flux02 = flux02/anorm2 
if (verbose >= v_user) then
  print *,'anorm2 = ',real(anorm2)
  print *,'flux_0,2 = ',real(flux02)
  print *,'S_0,2 = ',real(sbfac_2)
endif

! Surface brightness ratio at the centre of the stellar discs such that
! the average surface brightness on the hemisphere of the stars facing the
! companion is equal to the desired input value 
sbratio_0 = binary_pars(3) * sbfac_1/sbfac_2 
if (verbose >= v_user) then
  print *,'sbratio_0 = ',sbratio_0
endif
flux02 = flux02*sbratio_0
fpar2(1) = sbratio_0

! Add reflection effect parameters to fpar1/fpar2 if detailed reflection is
! being used.
if (binary_pars(29) > 0.0d0) then
  fpar1(19:21) = binary_pars(28:30)
  fpar1(18) = flux02
  fpar1(22) = radius2
elseif (binary_pars(28) > 0.0d0) then
  rfac_1 = flux02*binary_pars(28)*radius1**2
endif
if (binary_pars(32) > 0.0d0) then
  fpar2(19:21) = binary_pars(31:33)
  fpar2(18) = flux01
  fpar2(22) = radius1
elseif (binary_pars(31) > 0.0d0) then
  rfac_2 = flux01*binary_pars(31)*radius2**2 
endif

if (verbose >= v_user) print *,'Starting main calculation loop'

! Start main loop

do iobs=0,n_obs

  return_flags = return_flags_init 

  ! Note that we start at iobs=0 and use this zero-th iteration of the loop
  ! to calculate normalisation factor.
  if (iobs == 0) then
    time = time_0
  else
    time = input_times(iobs)
  endif

  if (verbose >= v_debug) then
    if (iobs > 0) then 
      print *,'time',input_times(iobs)
    else
      print *,'time_0',time_0
    endif
  endif

  ! Calculate positions of stars in their orbits 
  mm = twopi*mod(1.0d0+mod((time-tperi0)/p_anom,1.0d0),1.0d0)
  ee = eanom(mm,ecc)
  r = 1.0d0 - ecc*cos(ee)
  true_anomaly = 2.0d0*atan(efac*tan(ee/2.0d0))
  cosnu = cos(true_anomaly) 
  sinnu = sin(true_anomaly) 
  ! Calculate apparent positions of stars' centres-of-mass on the sky.
  incl = incl_0 + (time-time_0)*didt
  cosi = cos(incl)
  sini = sin(incl)
  omega_1 = mod(omega_0 + (time-time_0)*omdot/p_sid, twopi)
  cosom1 = cos(omega_1) 
  sinom1 = sin(omega_1) 
  omega_2 = mod(omega_1+pi,twopi)
  cosom2 = -cosom1
  sinom2 = -sinom1
  w1 = -r*sini*(sinnu*cosom1+cosnu*sinom1)*qfac1
  w2 = -r*sini*(sinnu*cosom2+cosnu*sinom2)*qfac2
  ! Light travel time correction
  if (dolite) then
    t1 = time + alite1*w1
    mm = twopi*mod((t1-tperi0)/p_anom,1.0d0)
    ee = eanom(mm,ecc)
    r_1 = 1.0d0 - ecc*cos(ee)
    true_anomaly_1 = 2.0d0*atan(efac*tan(ee/2.0d0))
    cosnu_1 = cos(true_anomaly_1) 
    sinnu_1 = sin(true_anomaly_1) 
    t2 = time + alite2*w2
    mm = twopi*mod((t2-tperi0)/p_anom,1.0d0)
    ee = eanom(mm,ecc)
    r_2 = 1.0d0 - ecc*cos(ee)
    true_anomaly_2 = 2.0d0*atan(efac*tan(ee/2.0d0))
    cosnu_2 = cos(true_anomaly_2) 
    sinnu_2 = sin(true_anomaly_2) 
  else
    r_1 = r
    true_anomaly_1 = true_anomaly
    cosnu_1 = cosnu
    sinnu_1 = sinnu 
    r_2 = r
    true_anomaly_2 = true_anomaly
    cosnu_2 = cosnu
    sinnu_2 = sinnu 
  endif
  ! Centre-of-mass positions on sky
  u1 = r_1*(cosnu_1*cosom1-sinnu_1*sinom1)*qfac1
  v1 = r_1*cosi*(sinnu_1*cosom1+cosnu_1*sinom1)*qfac1
  u2 = r_2*(cosnu_2*cosom2-sinnu_2*sinom2)*qfac2
  v2 = r_2*cosi*(sinnu_2*cosom2+cosnu_2*sinom2)*qfac2
  ! Centre-of-mass radial velocities
  if (dorv) then
    rv1 = vorb1*sini*(cos(true_anomaly_1+omega_1)+ecc*cosom1)
    rv2 = vorb2*sini*(cos(true_anomaly_2+omega_2)+ecc*cosom2)
  endif

  if (ecc > 0.0d0) then ! Re-calculate star shapes

    abcd1 = starshape(radius1, r_1, spar1, ecc, qmass1, imodel1, rtol, verbose1)
    if (verbose >= v_debug) print '(A,4F9.5)',' starshape: A1,B1,C1,D1 = ',abcd1
    if(abcd1(1) == bad_dble) then
      flux_rv_flag(iobs,1:5) = bad_dble
      return_flags = ibset(return_flags,b_ellc_error)
      flux_rv_flag(iobs,6) = return_flags
      if (verbose > v_silent) print *, 'End ELLC - error calling starshape'
      cycle
    endif
    fpar1(2:5) = abcd1(1:4)
    if (exact_grav) then
      fpar1(15) = droche(qmass1,x=0.0d0,y=0.0d0,z=abcd1(3),d=r,f=frot1)
      fpar1(27) = roche(abcd1(1)+abcd1(4),0.0d0,0.0d0, q=qmass1,d=r,f=frot1)
    else
      fpar1(14:16) = gmodel_coeffs(abcd1, r, frot1, qmass1,  verbose1)
    endif

    abcd2 = starshape(radius2, r_2, spar2, ecc, qmass2, imodel2, rtol, verbose1)
    if (verbose >= v_debug) print '(A,4F9.5)',' starshape: A2,B2,C2,D2 = ',abcd2
    if(abcd2(1) == bad_dble) then
      flux_rv_flag(iobs,1:5) = bad_dble
      return_flags = ibset(return_flags,b_ellc_error)
      flux_rv_flag(iobs,6) = return_flags
      if (verbose > v_silent) print *, 'End ELLC - error calling starshape'
      cycle
    endif
    fpar2(2:5) = abcd2(1:4)
    if (exact_grav) then
      fpar2(15) = droche(qmass2,x=0.0d0,y=0.0d0,z=abcd2(3),d=r,f=frot2)
      fpar2(27) = roche(abcd2(1)+abcd2(4),0.0d0,0.0d0, q=qmass2,d=r,f=frot2)
    else
      fpar2(14:16) = gmodel_coeffs(abcd2, r, frot2, qmass2,  verbose1)
    endif

  endif

  ! Apparent positions of centres of ellipsoids
  sep = r_1*qfac1-abcd1(4)+r_2*qfac2-abcd2(4)
  uapp1 = u1*(r_1-abcd1(4))/r_1
  vapp1 = v1*(r_1-abcd1(4))/r_1
  uapp2 = u2*(r_2-abcd2(4))/r_2
  vapp2 = v2*(r_2-abcd2(4))/r_2
  phi_1 = mod(twopi+true_anomaly_1+omega_1-halfpi,twopi)
  phi_2 = mod(twopi+true_anomaly_2+omega_2-halfpi,twopi)

  ! Project ellipsoids onto the sky (no need to re-project spheres)
  if (.not.sphere_1) then
    ellipse_1 =  ell_project_ellipsoid(abcd1(1:3),phi_1,incl)
  endif
  if (.not.sphere_2) then
    ellipse_2 =  ell_project_ellipsoid(abcd2(1:3),phi_2,incl)
  endif

  ! Translate ellipses to apparent positions of stars on the sky
  if (sphere_1) then
    ellipse_1 = ell_move(uapp1, vapp1, circle_1)
  else 
    ellipse_1 = ell_move(uapp1, vapp1, ellipse_1)
  endif
  if (sphere_2) then
    ellipse_2 = ell_move(uapp2, vapp2, circle_2)
  else
    ellipse_2 = ell_move(uapp2, vapp2, ellipse_2)
  endif

  if (verbose >= v_debug) then
    print *,'ellpar1',ellipse_1(i_ell_ellpar)
    print *,'ellpar2',ellipse_2(i_ell_ellpar)
    print *,'area1',ellipse_1(i_ell_area)
    print *,'area2',ellipse_2(i_ell_area)
  endif
  ! Minimum area for integration
  ecl_area_tol = atol*min(ellipse_1(i_ell_area),ellipse_2(i_ell_area))

  fpar1(6) = incl
  fpar1(7) = phi_1
  fpar1(8) = r
  fpar1(32) = 0 ! Disable coordinate transformation
  flux_1 = ellgauss(ellipse_1(i_ell_a_p),ellipse_1(i_ell_b_p),ngx1,bright, &
                   nfpar1,fpar1,verbose1) / anorm1
  if (dorvflux) then
    fpar1(26) = 1  ! rvflag
    rvflux_1 = ellgauss(ellipse_1(i_ell_a_p),ellipse_1(i_ell_b_p),ngx1, &
                        bright,nfpar1,fpar1,verbose1) / anorm1
    fpar1(26) =0  ! rvflag
  else
    rvflux_1 =0.0d0 
  endif

  fpar2(6) = incl
  fpar2(7) = phi_2
  fpar2(8) = r
  fpar2(32) = 0 ! Disable coordinate transformation
  flux_2 = ellgauss(ellipse_2(i_ell_a_p),ellipse_2(i_ell_b_p),ngx2,bright, &
                   nfpar2,fpar2,verbose1) / anorm2
  if (dorvflux) then
    fpar2(26) = 1  ! rvflag
    rvflux_2 = ellgauss(ellipse_2(i_ell_a_p),ellipse_2(i_ell_b_p),ngx2, &
                        bright,nfpar2,fpar2,verbose1) / anorm1
    fpar2(26) =0  ! rvflag
  else
    rvflux_2 =0.0d0 
  endif

  ! Test for eclipses
  if (iobs > 0) then

    area_flags = ell_ell_overlap(ellipse_1, ellipse_2, verbose1)
    eclipsed_area = area_flags(1)
    overlap = int(area_flags(2))
    if (btest(overlap,b_ell_error)) then
      if (verbose >= v_warn) then
        print *,'ellc: calculation failed for observations no.',iobs
      endif
      flux_rv_flag(iobs,1:5) = bad_dble
      flux_rv_flag(iobs,6) = b_ellc_fail
      cycle
    endif
    if (btest(overlap,b_ell_warn_inaccurate)) then
      return_flags = ibset(return_flags,b_ellc_warning)
      if (verbose >= v_warn) then
        print *,'ellc: warning from ell_ell_overlap, obs. no.',iobs
      endif
    endif

    if (verbose >= v_debug) then
      print *,'ellc: overlap area = ',eclipsed_area
      print *,'ellc: overlap type = ',overlap
    endif

    if (eclipsed_area < ecl_area_tol) then
      if (verbose >= v_debug) then
        print *,'ellc: Eclipsed area less then tolerance',ecl_area_tol
        print *,'ellc: Setting eclipsed_area to 0 '
      endif
      eclipsed_area = 0
      overlap = ibset(0,b_ell_no_overlap)
    endif

    ecl_flux_1 = 0
    ecl_flux_2 = 0
    ecl_rv_1 = 0
    ecl_rv_2 = 0
    eclipse_type = 0
    if (btest(overlap,b_ell_no_overlap)) then
      continue
    else
      eclipse_type = ibset(eclipse_type,b_ellc_eclipse)
      if (w1 > w2) then 
        eclipse_type = ibset(eclipse_type,b_ellc_star2_eclipsed)
      else
        eclipse_type = ibset(eclipse_type,b_ellc_star1_eclipsed)
      endif

      if (btest(overlap,b_ell_1_inside_2)) then
        if (w1 > w2) then 
          eclipse_type = ibset(eclipse_type,b_ellc_transit)
        else
          eclipse_type = ibset(eclipse_type,b_ellc_total)
        endif
      else if (btest(overlap,b_ell_2_inside_1)) then
        if (w1 > w2) then 
          eclipse_type = ibset(eclipse_type,b_ellc_total)
        else
          eclipse_type = ibset(eclipse_type,b_ellc_transit)
        endif
      else if (btest(overlap,b_ell_identical)) then
        eclipse_type = ibset(eclipse_type,b_ellc_total)
      else if (btest(overlap,b_ell_four_intersects)) then
        eclipse_type = ibset(eclipse_type,b_ellc_double_partial)
      endif

    endif

    return_flags = ior(return_flags,eclipse_type) 

    ! Calculation of flux loss due to each eclipse type
    if (btest(eclipse_type, b_ellc_eclipse)) then

      if (btest(eclipse_type, b_ellc_total)) then

        continue ! This case will be done after calculation of spot modulation

      else if(btest(eclipse_type, b_ellc_transit)) then

        if(btest(eclipse_type,b_ellc_star1_eclipsed)) then
          ! Integrate surface brightness of star 1 over area of star 2
          fpar1(28) = ellipse_2(i_ell_x_c)-ellipse_1(i_ell_x_c) 
          fpar1(29) = ellipse_2(i_ell_y_c)-ellipse_1(i_ell_y_c) 
          fpar1(30) = cos(ellipse_1(i_ell_phi)-ellipse_2(i_ell_phi))
          fpar1(31) = sin(ellipse_1(i_ell_phi)-ellipse_2(i_ell_phi))
          fpar1(32) = 1 ! Enable coordinate transformation
          ecl_flux_1=ellgauss(ellipse_2(i_ell_a_p), ellipse_2(i_ell_b_p),  &
          ngx1, bright, nfpar1, fpar1, verbose1)/anorm1
          if (dorvflux) then
            fpar1(26) = 1.0d0  ! rvflag
            ecl_rv_1 = ellgauss(ellipse_2(i_ell_a_p), ellipse_2(i_ell_b_p),  &
            ngx1,bright, nfpar1, fpar1, verbose1)/anorm1
            fpar1(26) =0.0d0  ! rvflag
          endif
        else
          ! Integrate surface brightness of star 2 over area of star 1
          fpar2(28) = ellipse_1(i_ell_x_c)-ellipse_2(i_ell_x_c) 
          fpar2(29) = ellipse_1(i_ell_y_c)-ellipse_2(i_ell_y_c)
          fpar2(30) = cos(ellipse_2(i_ell_phi)-ellipse_1(i_ell_phi))
          fpar2(31) = sin(ellipse_2(i_ell_phi)-ellipse_1(i_ell_phi))
          fpar2(32) = 1 ! Enable coordinate transformation
          ecl_flux_2=ellgauss(ellipse_1(i_ell_a_p), ellipse_1(i_ell_b_p),  &
          ngx2,bright, nfpar2, fpar2, verbose1)/anorm2
          if (dorvflux) then
            fpar2(26) = 1.0d0  ! rvflag
            ecl_rv_2 = ellgauss(ellipse_1(i_ell_a_p), ellipse_1(i_ell_b_p),  &
            ngx2,bright, nfpar2, fpar2, verbose1)/anorm2
            fpar2(26) =0.0d0  ! rvflag
          endif
        endif

      else if (btest(eclipse_type,b_ellc_double_partial)) then

        if(btest(eclipse_type, b_ellc_star1_eclipsed)) then
          avflux = double_partial(ellipse_1, ellipse_2, ngx1, fpar1, nfpar1, & 
           verbose=verbose1) 
          ecl_flux_1 = flux_1 - (ellipse_1(i_ell_area)-eclipsed_area)*avflux
          if (dorvflux) then
            fpar1(26) = 1.0d0  ! rvflag
            avflux = double_partial(ellipse_1, ellipse_2, ngx1, fpar1, & 
             nfpar1, verbose=verbose1) 
            ecl_rv_1 = rvflux_1 - (ellipse_1(i_ell_area)-eclipsed_area)*avflux
            fpar1(26) =0.0d0  ! rvflag
          endif

        else 
          avflux = double_partial(ellipse_2, ellipse_1, ngx2, fpar2, nfpar2, & 
           verbose=verbose1) 
          ecl_flux_2 = flux_2 - (ellipse_2(i_ell_area)-eclipsed_area)*avflux 
          if (dorvflux) then
            fpar2(26) = 1.0d0  ! rvflag
            avflux = double_partial(ellipse_2, ellipse_1, ngx2, fpar2, & 
             nfpar2, verbose=verbose1) 
            ecl_rv_2 = rvflux_2 - (ellipse_2(i_ell_area)-eclipsed_area)*avflux
            fpar2(26) =0.0d0  ! rvflag
          endif
        endif

      else   ! Partial eclipses.

        if(btest(eclipse_type, b_ellc_star1_eclipsed)) then

          if (eclipsed_area < (0.5d0*ellipse_1(i_ell_area))) then

            if (verbose >= v_debug) then
              print *,'ellc: b_ellc_star1_eclipsed, integrate_eclipsed=.true.'
            endif
            ecl_flux_1 = partial(ellipse_1, ellipse_2, ngx1, fpar1, nfpar1, & 
            integrate_eclipsed=.true.,verbose=verbose1) *eclipsed_area
            if (dorvflux) then
              fpar1(26) = 1.0d0  ! rvflag
              ecl_rv_1 =  partial(ellipse_1, ellipse_2, ngx1, fpar1, nfpar1, & 
              integrate_eclipsed=.true.,verbose=verbose1) *eclipsed_area
              fpar1(26) =0.0d0  ! rvflag
            endif

          else 

            if (verbose >= v_debug) then
              print *,'ellc: b_ellc_star1_eclipsed, integrate_eclipsed=.false.'
            endif
            avflux = partial(ellipse_1, ellipse_2, ngx1, fpar1, nfpar1, & 
            integrate_eclipsed=.false.,verbose=verbose1)
            ecl_flux_1 = flux_1 - (ellipse_1(i_ell_area)-eclipsed_area)*avflux
            if (dorvflux) then
              fpar1(26) = 1.0d0  ! rvflag
              avflux = partial(ellipse_1, ellipse_2, ngx1, fpar1, nfpar1, & 
              integrate_eclipsed=.false.,verbose=verbose1)
              ecl_rv_1 = rvflux_1 - (ellipse_1(i_ell_area)-eclipsed_area)*avflux
              fpar1(26) =0.0d0  ! rvflag
            endif

          endif

        else ! Star 2 is eclipsed

          if (eclipsed_area < (0.5d0*ellipse_2(i_ell_area))) then
            if (verbose >= v_debug) then
              print *,'ellc: b_ellc_star2_eclipsed, integrate_eclipsed=.true.'
            endif
            avflux = partial(ellipse_2, ellipse_1, ngx2, fpar2, nfpar2, & 
            integrate_eclipsed=.true.,verbose=verbose1)
            ecl_flux_2 =  eclipsed_area*avflux
            if (dorvflux) then
              fpar2(26) = 1.0d0  ! rvflag
              avflux = partial(ellipse_2, ellipse_1, ngx2, fpar2, nfpar2, & 
              integrate_eclipsed=.true.,verbose=verbose1)
              ecl_rv_2 =  eclipsed_area*avflux
              fpar2(26) =0.0d0  ! rvflag
            endif
          else 
            if (verbose >= v_debug) then
              print *,'ellc: b_ellc_star2_eclipsed, integrate_eclipsed=.false.'
            endif
            avflux = partial(ellipse_2, ellipse_1, ngx2, fpar2, nfpar2, & 
            integrate_eclipsed=.false.,verbose=verbose1)
            ecl_flux_2 = flux_2 - (ellipse_2(i_ell_area)-eclipsed_area) &
            * avflux
            if (dorvflux) then
              fpar2(26) = 1.0d0  ! rvflag
              avflux = partial(ellipse_2, ellipse_1, ngx2, fpar2, nfpar2, & 
              integrate_eclipsed=.false.,verbose=verbose1)
              ecl_rv_2 = rvflux_2 - (ellipse_2(i_ell_area)-eclipsed_area) &
              * avflux
              fpar2(26) =0.0d0  ! rvflag
            endif
          endif

        endif

      endif 

    endif ! End calculation of eclipsed flux

    ! Star spots
    ell_ell_fail = .false.
    spot_flux_1 = 0
    spot_ecl_flux_1 = 0
    spot_rv_1 = 0
    spot_ecl_rv_1 = 0
    do i_spot = 1, n_spot_1
      ii = ii_1(iobs,i_spot)
      df = df_1(iobs,i_spot)
      spot_flux_1 = spot_flux_1 + (df - 1.0d0)*flux_1
      if ((ii > 0).and.btest(eclipse_type, b_ellc_star1_eclipsed) &
           .and.(.not.btest(eclipse_type, b_ellc_total))) then
        ! Spots on star 1 may be eclipsed
        phirot = phi_rot_1(iobs)
        lat_i = spots_1(i_spot_lat,i_spot)*dtor
        lon_i = spots_1(i_spot_lon,i_spot)*dtor
        u_s = sin(phirot - lon_i)*cos(lat_i)
        v_s = sin(lat_i)*sin(incl_0)-cos(incl_0)*cos(phirot - lon_i)*cos(lat_i)
        w_s = cos(phirot - lon_i)*cos(lat_i)*sin(incl_0)+sin(lat_i)*cos(incl_0)
        alpha_s = atan2(v_s,u_s)
        beta_s  = asin(w_s)
        gamma_s = spots_1(i_spot_gam,i_spot)*dtor
        if (verbose >= v_debug) then
          print *,'Star 1, spot',i_spot,' phi_rot = ', phirot
          print *,'Star 1, spot',i_spot,' u, v, w = ', u_s,v_s,w_s
          print *,'Star 1, spot',i_spot,' alpha, beta, gamma, ii = ', &
            alpha_s,beta_s,gamma_s,ii
          print *,'Star 1, spot',i_spot,' lat_i,lon_i,df = ',&
            lat_i,lon_i,df
        endif
        ! If beta_s is small then the calculation of the algorithm for the 
        ! occulted spot area is unreliable. In this case, run the algorithm
        ! twice for values of beta_s either side of the 0 and interpolate to the
        ! actual value of beta_s.
        if (abs(beta_s) < beta_s_lim) then
          n_spot_calc = 2
        else
          n_spot_calc = 1
        endif
        if (verbose >= v_debug) print *,'n_spot_calc=',n_spot_calc
        do i_spot_calc = 1, n_spot_calc
          if (n_spot_calc == 1) then
            call project_spot(alpha_s, beta_s, gamma_s, ellipse_s, xy_tng)
            ! Could use ii to determine if spot is on the limb, (iiswitch=ii) 
            ! but this sometimes fails because project_spot() finds no tangent
            ! points, so calculate iiswitch here based on xy_tng and beta_s.
            if (xy_tng(1,1) == not_set_dble) then
              if (beta_s < 0) then
                iiswitch = 0
              else
                iiswitch = 3
              endif
            else
              if (beta_s < 0) then
                iiswitch = 1
              else
                iiswitch = 2
              endif
            endif

          else

            if (i_spot_calc == 1) then
              call project_spot(alpha_s,beta_s_lim,gamma_s,ellipse_s,xy_tng)
              if (beta_s_lim < gamma_s) then
                iiswitch = 2
              else
                iiswitch = 3
              endif
            else
              if (beta_s_lim > gamma_s) then
                iiswitch = 0
              else
                call project_spot(alpha_s,-beta_s_lim, gamma_s,ellipse_s,xy_tng)
                iiswitch = 1
              endif
            endif
            if (verbose >= v_debug) then
              print *,'i_spot_calc,beta_s_lim,gamma_s,iiswitch = ', &
                i_spot_calc,beta_s_lim,gamma_s,iiswitch
            endif
          endif
          ! Affine transformation that translates projected ellipse for star 1
          ! to the origin and scales it by the radius of the ellipsoid at the
          ! centre of the spot. Using an approximation here that the line of
          ! sight is parallel to the line between the centres-of-mass for the
          ! two stars - not exactly true for eccentric orbits with i<90degrees,
          ! but offset is usually small.
          r_spot = sqrt( &
             (abcd1(1)*cos(lon_i)*cos(lat_i))**2 + &
             (abcd1(2)*sin(lon_i)*cos(lat_i))**2 + &
             (abcd1(3)*sin(lat_i))**2 )
          tr(1,1) =  1.0d0/r_spot
          tr(1,2) =  0.0d0
          tr(2,1) =  0.0d0
          tr(2,2) =  1.0d0/r_spot
          tr(1,3) = -ellipse_1(i_ell_x_c)/ellipse_1(i_ell_a_p)
          tr(2,3) = -ellipse_1(i_ell_y_c)/ellipse_1(i_ell_a_p)
          ! Apply this transformation to ellipse_2
          ellipse_t = ell_affine(tr, ellipse_2)
          select case (iiswitch)
          case (0)
            !  This is the case where we are interpolating between
            ! beta = +/-beta_s_lim, and the spot radius gamma_s < beta_s_lim
            ! so that the spot is not visible for beta = -beta_s_lim.
            !  Test whether the last point of the spot that was visible as it
            ! rotated off the limb was eclipsed or not.
            call project_spot(alpha_s,-gamma_s, gamma_s,ellipse_s,xy_tng)
            if (ell_point_is_inside(xy_tng(1:2,1),ellipse_t)) then
              frac(i_spot_calc) = 0
            else
              frac(i_spot_calc) = 1
            endif
          case (1)
            large=.false.
            frac(i_spot_calc) = spot_limb_eclipse(ellipse_t, ellipse_s, &
            xy_tng,large,verbose1)
            if (frac(i_spot_calc) == bad_dble) then
              ell_ell_fail = .true.
             exit
           endif
          case (2)
            large=.true.
            frac(i_spot_calc) = spot_limb_eclipse(ellipse_t, ellipse_s, &
            xy_tng,large,verbose1)
            if (frac(i_spot_calc) == bad_dble) then
              ell_ell_fail = .true.
             exit
           endif
          case (3)
            area_flags = ell_ell_overlap(ellipse_t, ellipse_s, verbose1)
            if (btest(overlap,b_ell_error)) then
              if (verbose >= v_warn) then
                print *,'ellc: calculation failed for observations no.',iobs
              endif
              ell_ell_fail = .true.
              exit
            endif
            if (btest(overlap,b_ell_warn_inaccurate)) then
              return_flags = ibset(return_flags,b_ellc_warning)
              if (verbose >= v_warn) then
                print *,'ellc: ell_ell_overlap warning , spot 1,',i_spot_calc
              endif
            endif
            frac(i_spot_calc) = area_flags(1)/ellipse_s(i_ell_area) 
          end select
        end do
        if (n_spot_calc == 1) then
          wt = 1
        else
          if (iiswitch == 0) then
            wt = (beta_s+gamma_s)/(beta_s_lim+gamma_s)
          else
            wt = 0.5d0 + 0.5d0*beta_s/beta_s_lim
          endif
        endif
        if (verbose >= v_debug) then
          print *,'iiswitch,frac,wt',iiswitch,frac,wt
        endif
        df1 =  (df-1.0d0)*flux_1*(wt*frac(1) + (1.0d0-wt)*frac(2))
        spot_ecl_flux_1 = spot_ecl_flux_1 + df1
        if (dorvflux) then
          spot_ecl_rv_1 = spot_ecl_rv_1  + df1*u_s*vsini1
        endif
      endif

      if (dorvflux) then
        phirot = phi_rot_1(iobs)
        lat_i = spots_1(i_spot_lat,i_spot)*dtor
        lon_i = spots_1(i_spot_lon,i_spot)*dtor
        u_s = sin(phirot - lon_i)*cos(lat_i)
        spot_rv_1 = spot_rv_1  + (df - 1.0d0)*u_s*vsini1
      endif

      if (verbose >= v_debug) then
        print *,'i_spot,spot_flux_1,ii,df,df1=',&
          i_spot,spot_flux_1,ii,df ,df1
      endif

    end do

 ! ell_ell_intersect failed in the loop
    if (ell_ell_fail) then
      flux_rv_flag(iobs,1:5) = bad_dble
      flux_rv_flag(iobs,6) = b_ellc_fail
      cycle
    endif


    spot_flux_2 = 0
    spot_ecl_flux_2 = 0 
    spot_rv_2 = 0
    spot_ecl_rv_2 = 0
    do i_spot = 1, n_spot_2
      ii = ii_2(iobs,i_spot)
      df = df_2(iobs,i_spot)
      spot_flux_2 = spot_flux_2 + (df - 1.0d0)*flux_2
      if ((ii > 0).and.btest(eclipse_type, b_ellc_star2_eclipsed) &
           .and.(.not.btest(eclipse_type, b_ellc_total))) then
        ! Spots on star 2 may be eclipsed
        phirot = phi_rot_2(iobs)
        lat_i = spots_2(i_spot_lat,i_spot)*dtor
        lon_i = spots_2(i_spot_lon,i_spot)*dtor + pi
        u_s = sin(phirot - lon_i)*cos(lat_i)
        v_s = sin(lat_i)*sin(incl_0)-cos(incl_0)*cos(phirot - lon_i)*cos(lat_i)
        w_s = cos(phirot - lon_i)*cos(lat_i)*sin(incl_0)+sin(lat_i)*cos(incl_0)
        alpha_s = atan2(v_s,u_s)
        beta_s  = asin(w_s)
        gamma_s = spots_2(i_spot_gam,i_spot)*dtor
        if (verbose >= v_debug) then
          print *,'Star 2, spot',i_spot,' phi_rot = ', phirot
          print *,'Star 2, spot',i_spot,' u, v, w = ', u_s,v_s,w_s
          print *,'Star 2, spot',i_spot,' alpha, beta, gamma, ii = ', &
            alpha_s,beta_s,gamma_s,ii
        endif
        ! If beta_s is small then the calculation of the algorithm for the 
        ! occulted spot area is unreliable. In this case, run the algorithm
        ! twice for values of beta_s either side of the 0 and interpolate to the
        ! actual value of beta_s.
        if (abs(beta_s) < beta_s_lim) then
          n_spot_calc = 2
        else
          n_spot_calc = 1
        endif
        do i_spot_calc = 1, n_spot_calc

          if (n_spot_calc == 1) then
            call project_spot(alpha_s, beta_s, gamma_s, ellipse_s, xy_tng)
            ! Could use ii to determine if spot is on the limb, (iiswitch=ii) 
            ! but this sometimes fails because project_spot() finds no tangent
            ! points, so calculate iiswitch here based on xy_tng and beta_s.
            if (xy_tng(1,1) == not_set_dble) then
              if (beta_s < 0) then
                iiswitch = 0
              else
                iiswitch = 3
              endif
            else
              if (beta_s < 0) then
                iiswitch = 1
              else
                iiswitch = 2
              endif
            endif

          else

            if (i_spot_calc == 1) then
              call project_spot(alpha_s,beta_s_lim,gamma_s,ellipse_s,xy_tng)
              if (beta_s_lim < gamma_s) then
                iiswitch = 2
              else
                iiswitch = 3
              endif
            else
              if (beta_s_lim > gamma_s) then
                iiswitch = 0
              else
                call project_spot(alpha_s,-beta_s_lim, gamma_s,ellipse_s,xy_tng)
                iiswitch = 1
              endif
            endif
            if (verbose >= v_debug) then
              print *,'i_spot_calc,beta_s_lim,gamma_s,iiswitch = ', &
                i_spot_calc,beta_s_lim,gamma_s,iiswitch
            endif
          endif
          ! Affine transformation that translates projected ellipse for star 2
          ! to the origin and scales it by the radius of the ellipsoid at the
          ! centre of the spot. Using an approximation here that the line of
          ! sight is parallel to the line between the centres-of-mass for the
          ! two stars - not exactly true for eccentric orbits with i<90degrees,
          ! but offset is usually small.
          r_spot = sqrt( &
             (abcd2(1)*cos(lon_i)*cos(lat_i))**2 + &
             (abcd2(2)*sin(lon_i)*cos(lat_i))**2 + &
             (abcd2(3)*sin(lat_i))**2 )
          tr(1,1) =  1.0d0/r_spot
          tr(1,2) =  0.0d0
          tr(2,1) =  0.0d0
          tr(2,2) =  1.0d0/r_spot
          tr(1,3) = -ellipse_2(i_ell_x_c)/ellipse_2(i_ell_a_p)
          tr(2,3) = -ellipse_2(i_ell_y_c)/ellipse_2(i_ell_a_p)
          ! Apply this transformation to ellipse_1
          ellipse_t = ell_affine(tr, ellipse_1)
          select case (iiswitch)
          case (0)
            !  This is the case where we are interpolating between
            ! beta = +/-beta_s_lim, and the spot radius gamma_s < beta_s_lim
            ! so that the spot is not visible for beta = -beta_s_lim.
            !  Test whether the last point of the spot that was visible as it
            ! rotated off the limb was eclipsed or not.
            call project_spot(alpha_s,-gamma_s, gamma_s,ellipse_s,xy_tng)
            if (ell_point_is_inside(xy_tng(1:2,1),ellipse_t)) then
              frac(i_spot_calc) = 0
            else
              frac(i_spot_calc) = 1
            endif
          case (1)
            large=.false.
            frac(i_spot_calc) = spot_limb_eclipse(ellipse_t, ellipse_s, &
            xy_tng,large,verbose1)
            if (frac(i_spot_calc) == bad_dble) then
              ell_ell_fail = .true.
             exit
           endif
          case (2)
            large=.true.
            frac(i_spot_calc) = spot_limb_eclipse(ellipse_t, ellipse_s, &
            xy_tng,large,verbose1)
            if (frac(i_spot_calc) == bad_dble) then
              ell_ell_fail = .true.
             exit
           endif
          case (3)
            area_flags = ell_ell_overlap(ellipse_s, ellipse_t, verbose1)
            if (btest(overlap,b_ell_error)) then
              if (verbose >= v_warn) then
                print *,'ellc: calculation failed for observations no.',iobs
              endif
              ell_ell_fail = .true.
              exit
            endif
            if (btest(overlap,b_ell_warn_inaccurate)) then
              return_flags = ibset(return_flags,b_ellc_warning)
              if (verbose >= v_warn) then
                print *,'ellc: ell_ell_overlap warning , spot 2,',i_spot_calc
              endif
            endif
            frac(i_spot_calc) = area_flags(1)/ellipse_s(i_ell_area) 
          end select
        end do
        if (n_spot_calc == 1) then
          wt = 1
        else
          if (iiswitch == 0) then
            wt = (beta_s+gamma_s)/(beta_s_lim+gamma_s)
          else
            wt = 0.5d0 + 0.5d0*beta_s/beta_s_lim
          endif
        endif
        if (verbose >= v_debug) then
          print *,'iiswitch,frac,wt',iiswitch,frac,wt
        endif
        df2 =  (df-1.0d0)*flux_2*(wt*frac(1) + (1.0d0-wt)*frac(2))
        spot_ecl_flux_2 = spot_ecl_flux_2 + df2
        if (dorvflux) then
          spot_ecl_rv_2 = spot_ecl_rv_2  + df2*u_s*vsini2
        endif
      endif

      if (dorvflux) then
        phirot = phi_rot_2(iobs)
        lat_i = spots_2(i_spot_lat,i_spot)*dtor
        lon_i = spots_2(i_spot_lon,i_spot)*dtor
        u_s = sin(phirot - lon_i)*cos(lat_i)
        spot_rv_2 = spot_rv_2  + (df - 1.0d0)*u_s*vsini2
      endif

      if (verbose >= v_debug) then
        print *,'i_spot,spot_flux_2,ii,df=',i_spot,spot_flux_2,ii,df 
      endif

    end do

    if (ell_ell_fail) then
      flux_rv_flag(iobs,1:5) = bad_dble
      flux_rv_flag(iobs,6) = b_ellc_fail
      cycle
    endif

    ! Have delayed calculation of ecl_flux_1,ecl_flux_2 for the total eclipse
    ! case until here so that the flux modulation due to spots is properly
    ! accounted for.
    if (btest(eclipse_type, b_ellc_total)) then
      if(btest(eclipse_type, b_ellc_star1_eclipsed)) then
        ecl_flux_1 = flux_1
        ecl_rv_1 = rvflux_1
        spot_ecl_flux_1 = spot_flux_1
      else
        ecl_flux_2 = flux_2
        ecl_rv_2 = rvflux_2
        spot_ecl_flux_2 = spot_flux_2
      endif
    endif

    if (verbose >= v_debug) then
      print *,'spot_flux_1,spot_ecl_flux_1,spot_rv_1 =', &
        spot_flux_1,spot_ecl_flux_1,spot_rv_1
      print *,'spot_flux_2,spot_ecl_flux_2,spot_rv_2 =', &
        spot_flux_2,spot_ecl_flux_2,spot_rv_2
    endif
    
    ! Ensure correction for eclipsed spots does not exceed total flux 
    ! lost in eclipse.
    if (spot_ecl_flux_1 < -ecl_flux_1) spot_ecl_flux_1 = -ecl_flux_1
    if (spot_ecl_flux_2 < -ecl_flux_2) spot_ecl_flux_2 = -ecl_flux_2


    ! Add effect of spots to light/rv curves
    flux_1 = flux_1 + spot_flux_1 - spot_ecl_flux_1
    flux_2 = flux_2 + spot_flux_2 - spot_ecl_flux_2

    rvflux_1 = rvflux_1 + spot_rv_1 - spot_ecl_rv_1
    rvflux_2 = rvflux_2 + spot_rv_2 - spot_ecl_rv_2
    
    ! Simple reflection
    if ((binary_pars(29) == 0.0d0).or.(binary_pars(32) == 0.0d0)) then
      heat=sini*cos(phi_1)
      heat2=0.5d0 + 0.5d0*heat**2
      if (binary_pars(29) == 0.0d0) then
        refl_1 = rfac_1*(heat2+heat)/r**2
        if (flux_1 > 0) refl_1 = refl_1 * (1.0d0 - ecl_flux_1/flux_1)
      endif
      if (binary_pars(32) == 0.0d0) then
        refl_2 = rfac_2*(heat2-heat)/r**2
        if (flux_2 > 0) refl_2 = refl_2 * (1.0d0 - ecl_flux_2/flux_2)
      endif
    endif

    ! Subtract eclipsed flux from total flux for each star
    if (verbose >= v_debug) then
      print *,'flux_1,rv1,ecl_flux_1', flux_1,rv1,ecl_flux_1
      print *,'flux_2,rv2,ecl_flux_2', flux_2,rv2,ecl_flux_2
    endif
    flux_1 = flux_1 - ecl_flux_1
    flux_2 = flux_2 - ecl_flux_2

    ! Flux-weighted radial velocities 
    if (dorvflux) then
      if (flux_1 /= 0.0d0) then
        rv1 = rv1 + (rvflux_1 - ecl_rv_1)/flux_1 
      else
        rv1 =0
      endif
      if (flux_2 /= 0.0d0) then
        rv2 = rv2 + (rvflux_2 - ecl_rv_2)/flux_2 
      else
        rv2 =0
      endif
    endif

    ! Doppler boosting
    flux_1 = flux_1*(1.0d0 - binary_pars(26)*rv1/c_kms)
    flux_2 = flux_2*(1.0d0 - binary_pars(27)*rv2/c_kms)

    if (verbose >= v_debug) then
      print *,'flux_1,rv1,ecl_rv_1,refl_1', flux_1,rv1,ecl_rv_1,refl_1
      print *,'flux_2,rv2,ecl_rv_2,refl_2', flux_2,rv2,ecl_rv_2,refl_2
    endif

    flux_rv_flag(iobs,1) = (flux_1+flux_2+flux_3+refl_1+refl_2)/fnorm
    flux_rv_flag(iobs,2) = flux_1+refl_1
    flux_rv_flag(iobs,3) = flux_2+refl_2
    flux_rv_flag(iobs,4) = rv1
    flux_rv_flag(iobs,5) = rv2
    flux_rv_flag(iobs,6) = return_flags

  else  ! iobs=0, calculation of normalized flux

    ! Simple reflection
    if ((binary_pars(29) == 0.0d0).or.(binary_pars(32) == 0.0d0)) then
      heat=sini*cos(phi_1)/r**2
      heat2=0.5d0 + 0.5d0*heat**2
      if (binary_pars(29) == 0.0d0) then
        refl_1 = rfac_1*(heat2+heat)
      endif
      if (binary_pars(32) == 0.0d0) then
        refl_2 = rfac_2*(heat2-heat)
      endif
    endif

    fnorm = flux_1 + flux_2 + refl_1 + refl_2
    flux_3 = l_3 * fnorm
    fnorm = flux_1 + flux_2 + flux_3 + refl_1 + refl_2
    if (verbose >= v_debug) then
      print *,'f_norm = ', fnorm
    endif
  endif

end do  ! End of main loop


deallocate(fpar1)
deallocate(fpar2)
if ((n_spot_1+n_spot_2) > 0) then 
  deallocate(phi_rot_1)
  deallocate(phi_rot_2)
  deallocate(df_1)
  deallocate(df_2)
  deallocate(ii_1)
  deallocate(ii_2)
endif

if (verbose >= v_user) print *, 'End ellc:lc'
return

end function lc

!------------------------------------------------------------------------------

function rv(n_obs,               &  ! Number of observations
            input_times,         &  ! Array of times/phases 
            binary_pars,         &  ! Parameters of the binary system
            verbose)             &  ! Verbosity of printed output
            result(rv_result)
implicit none
integer, intent(in)   :: n_obs
!f2py integer, intent(hide), depend(input_times) :: n_obs = len(input_times)
double precision, intent(in)  :: input_times(n_obs)
!f2py integer, parameter :: n_par = 39
double precision, intent(in)  :: binary_pars(n_par)
integer, intent(in)   :: verbose
double precision :: rv_result(n_obs,2)

!Local variables
integer :: iobs
double precision :: time_0,p_anom,p_anom_s,ecc,efac,omega_0,incl_0
double precision :: sini_0, a,qmass1,qmass2,qfac1,qfac2,omdot,p_sid,didt
double precision :: alite1,alite2,dltte,sini,cosi,cosnu,sinnu,time,tperi0
double precision :: vorb1, vorb2, w1, w2,sinom1, sinom2
double precision :: true_anomaly, true_anomaly_1, true_anomaly_2
double precision :: ee,mm,incl,r,rv1,rv2, omega_1, omega_2,r_1,r_2,t1,t2
double precision :: sinnu_1, sinnu_2, cosnu_1, cosnu_2, cosom1, cosom2

if (verbose >= v_user) then
  print *,'Start ellc:lc'
  print *,'N_obs  = ',n_obs
  print *,'t_obs(1)  = ',input_times(1)
  print *,'t_obs(N_obs)  = ',input_times(n_obs)
endif


! Some useful variables
time_0 = binary_pars(1)
p_anom = binary_pars(2)
p_anom_s = p_anom*86400.0d0
ecc = binary_pars(9)**2 + binary_pars(10)**2 
if (ecc >= 1) then
  rv_result(1:n_obs,1:2) = bad_dble
  return
endif

efac = sqrt((1.0d0+ecc)/(1.0d0-ecc))
if (ecc == 0.0d0) then
  omega_0 = 0.0d0
else
  omega_0 = atan2(binary_pars(10),binary_pars(9))
endif
incl_0 = binary_pars(6)*dtor
if (verbose >= v_user) then
  print *,'ellc: time_0 = ',time_0
  print *,'ellc: p_anom = ',p_anom
  print *,'ellc: e = ',real(ecc),'; omega_0 = ',omega_0,' radians'
endif
sini_0 = sin(incl_0) 
a = binary_pars(8)
qmass1 = binary_pars(11) ! Mass of companion to star 1 w.r.t. m_1
qmass2 = 1.0d0/qmass1    ! Mass of companion to star 2 w.r.t. m_2
qfac2 = 1.0d0/(1.0d0+qmass1)
qfac1 = qmass1*qfac2
omdot = binary_pars(23)*dtor
p_sid = p_anom*(1.0d0 - omdot/twopi)  ! Siderial period
if ((omdot /= 0.0d0).and.(verbose >= v_user)) then
  print *,'ellc: omdot = ',omdot,' radians/(siderial period)'
  print *,'ellc: p_sid = ',p_sid
endif
didt = binary_pars(22)*dtor
alite1 = binary_pars(8)*qfac1 * solar_radius/iau_c/8.64d4
alite2 = binary_pars(8)*qfac2 * solar_radius/iau_c/8.64d4
! Correction to T_0 for light travel time - see Borkovits et al., 
!   2015MNRAS.448..946B, equation (25)
dltte = alite2*sini_0*(qmass1-1.0d0)/(qmass1+1.0d0) & 
        * (1-ecc**2)/(1+ecc*sin(omega_0))
time_0 = time_0 - dltte
if (verbose >= v_user) then
  print *,'Light travel time correction to T_0 = ', real(dltte)
endif
vorb1 = a*qfac1/(solar_asini_kms_d*p_anom*sqrt(1-ecc**2))
vorb2 = qmass2*vorb1
if (verbose >= v_user) then
  print *,'K_1 = ',real(vorb1*sini_0),' km/s.'
  print *,'K_2 = ',real(vorb2*sini_0),' km/s.'
endif


! Time of periastron passage prior to time_0 via eccentric anomaly
tperi0 = t_ecl_to_peri(time_0, ecc, omega_0, incl_0, p_sid, verbose)
if (verbose >= v_user) print *,'Reference time of periastron = ', real(tperi0)

do iobs=1,n_obs

  time = input_times(iobs)
  ! Calculate positions of stars in their orbits 
  mm = twopi*mod(1.0d0+mod((time-tperi0)/p_anom,1.0d0),1.0d0)
  ee = eanom(mm,ecc)
  r = 1.0d0 - ecc*cos(ee)
  true_anomaly = 2.0d0*atan(efac*tan(ee/2.0d0))
  cosnu = cos(true_anomaly) 
  sinnu = sin(true_anomaly) 
  ! Calculate apparent positions of stars' centres-of-mass on the sky.
  incl = incl_0 + (time-time_0)*didt
  cosi = cos(incl)
  sini = sin(incl)
  omega_1 = mod(omega_0 + (time-time_0)*omdot/p_sid, twopi)
  cosom1 = cos(omega_1) 
  sinom1 = sin(omega_1) 
  omega_2 = mod(omega_1+pi,twopi)
  cosom2 = -cosom1
  sinom2 = -sinom1
  w1 = -r*sini*(sinnu*cosom1+cosnu*sinom1)*qfac1
  w2 = -r*sini*(sinnu*cosom2+cosnu*sinom2)*qfac2
  ! Light travel time correction
  t1 = time + alite1*w1
  mm = twopi*mod((t1-tperi0)/p_anom,1.0d0)
  ee = eanom(mm,ecc)
  r_1 = 1.0d0 - ecc*cos(ee)
  true_anomaly_1 = 2.0d0*atan(efac*tan(ee/2.0d0))
  cosnu_1 = cos(true_anomaly_1) 
  sinnu_1 = sin(true_anomaly_1) 
  t2 = time + alite2*w2
  mm = twopi*mod((t2-tperi0)/p_anom,1.0d0)
  ee = eanom(mm,ecc)
  r_2 = 1.0d0 - ecc*cos(ee)
  true_anomaly_2 = 2.0d0*atan(efac*tan(ee/2.0d0))
  cosnu_2 = cos(true_anomaly_2) 
  sinnu_2 = sin(true_anomaly_2) 
  rv1 = vorb1*sini*(cos(true_anomaly_1+omega_1)+ecc*cosom1)
  rv2 = vorb2*sini*(cos(true_anomaly_2+omega_2)+ecc*cosom2)
  rv_result(iobs,1:2) = [rv1, rv2]

  if (verbose >= v_debug) then
    print *,'time, rv1, rv2',time,rv1,rv2
  endif

end do


if (verbose >= v_user) print *, 'End ellc:rv'
return

end function rv
!------------------------------------------------------------------------------

double precision function partial(ellipse_a, ellipse_b, ngx, fpar, nfpar, &
                           integrate_eclipsed, verbose)
! Returns the average surface brightness of ellipse_a either in the region
! covered by ellipse_b or in the area not covered by ellipse_b, depending on the
! value of the switch integrate_eclipsed. The area of this region is calculated
! numerically so that the errors in the eclipse/non-eclipsed area and total flux
! partially cancel out.
implicit none
integer, intent(in) :: ngx, nfpar, verbose
!f2py integer, parameter :: n_ell_par = 14
double precision, intent(in) :: ellipse_a(n_ell_par), ellipse_b(n_ell_par)
double precision, intent(inout) :: fpar(nfpar)
!f2py intent(in,out) :: fpar
logical, intent(in) :: integrate_eclipsed
! integrate_eclipsed
!  .true.  => integrate eclipsed area of ellipse_a 
!  .false. => integrate visible area and ellipse_a

! Local variables
double precision :: um,vm
double precision :: qline(4)
double precision :: dudf,dvdf,dudg,dvdg
double precision :: fa(2),fb(2),uv(2)
double precision :: flima, flimb
double precision :: part1,part2,part3
double precision :: area1,area2,area3,earea,eflux
double precision :: uv_intersect(2,4)
integer, parameter :: nelimpar=16
double precision :: elimpar(nelimpar)
integer  :: flags, ngf, verbose1
integer,parameter :: ngmin = 4 ! Minimum size of integration grid

verbose1 = verbose_for_calls(verbose)

! Find intersection points of ellipses.

call ell_ell_intersect(ellipse_a, ellipse_b, verbose1, flags, uv_intersect)
if (.not.btest(flags, b_ell_two_intersects)) then
 print *,'partial: n_intersect /=  2'
 print *, ellipse_a
 print *, ellipse_b
 print *, flags
 stop
endif
     
if (verbose >= v_debug) then
  print *,'partial: u_intersect = ', uv_intersect(1,1:2)
  print *,'partial: v_intersect = ', uv_intersect(2,1:2)
endif
! Mid-point of intersection line
! This is the origin of the (f,g) coordinate system.
! The variable "f" runs perpendicular to the line of intersection.
! The variable "g" runs along the line of intersection.
um = 0.5d0* (uv_intersect(1,1)+uv_intersect(1,2))
vm = 0.5d0* (uv_intersect(2,1)+uv_intersect(2,2))
if (verbose >= v_debug) print *,'partial: (um,vm) = ',um,vm 
dudg = uv_intersect(1,2) - uv_intersect(1,1)
dvdg = uv_intersect(2,2) - uv_intersect(2,1)
dvdf = -dudg
dudf = dvdg
! Parametric equation of line along the "f" axis in (u,v) coordinates.
qline(1) = um
qline(2) = vm
qline(3) = dudf
qline(4) = dvdf

! Intersection of "f" axis with each ellipse.
fa = ell_line_intersect(ellipse_a, qline)
if (fa(1) == -huge(0.d0))  then
  print *,'Error calling ell_line_intersect(ellipse_a, qline)'
  print *,ellipse_a
  print *,qline
  stop
endif
fb = ell_line_intersect(ellipse_b, qline)
if (fb(1) == -huge(0.d0))  then
  print *,'Error calling ell_line_intersect(ellipse_b, qline)'
  print *,ellipse_b
  print *,qline
  stop
endif
! Identify which values of f are for points interior/exterior to the other
! ellipse and use these to identify  the value of f required to set the 
! upper limit for integration in the (u,v) plane. 
uv(:) = [um + dudf*fa(1) ,  vm + dvdf*fa(1) ]
if (ell_point_is_inside(uv,ellipse_b)) then
  if (integrate_eclipsed) then
    flima = fa(1)
  else
    flima = fa(2)
  endif
else
  if (integrate_eclipsed) then
    flima = fa(2)
  else
    flima = fa(1)
  endif
endif
uv(:) = [um + dudf*fb(1) ,  vm + dvdf*fb(1)]
if (ell_point_is_inside(uv,ellipse_a)) then
  flimb = fb(1)
else
  flimb = fb(2)
endif

! This is the transformation matrix from the (f,g) coordinate system to 
! the (s,t) coordinate system within bright.
fpar(28) = um-ellipse_a(i_ell_x_c)
fpar(29) = vm-ellipse_a(i_ell_y_c)
fpar(30) = dudf
fpar(31) = dudg
fpar(32) = 1  ! Enable coordinate transformation

elimpar(1) = um
elimpar(2) = vm
elimpar(3) = dudg
elimpar(4) = dvdg
elimpar(5:10) =  ellipse_a(i_ell_qcoeff)
elimpar(11:16) =  ellipse_b(i_ell_qcoeff)

if (integrate_eclipsed) then
  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flima,dvdf*flima)/ellipse_a(i_ell_a_p))),ngx)
  if (verbose >= v_debug) then
    print *,'partial: ',1,flima,ngf
    print *,'partial: ',1,elimpar
  endif
  part1 = gauss2d(ngf,bright,0.0d0,flima,glimnega,glimposa, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area1 = gauss2d(ngf,unitfunc,0.0d0,flima,glimnega,glimposa, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area1 < 0) then
    part1 = -part1
    area1 = -area1
  endif

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flimb,dvdf*flimb)/ellipse_a(i_ell_a_p))),ngx)
  if (verbose >= v_debug) then
    print *,'partial: ',2,flimb,ngf
    print *,'partial: ',2,elimpar
  endif
  part2 = gauss2d(ngf,bright,0.0d0,flimb,glimnegb,glimposb,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area2 = gauss2d(ngf,unitfunc,0.0d0,flimb,glimnegb,glimposb,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area2 < 0) then
    part2 = -part2
    area2 = -area2
  endif

  eflux = (part1 + part2)
  earea = (area1 + area2)

else

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flimb,dvdf*flimb)/ellipse_a(i_ell_a_p))),ngx)
  if (verbose >= v_debug) then
    print *,'partial: ',3,flimb,ngf
    print *,'partial: ',3,elimpar
  endif
  part1 = gauss2d(ngf,bright,0.0d0,flimb,glimnegb,glimnega, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area1 = gauss2d(ngf,unitfunc,0.0d0,flimb,glimnegb,glimnega, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area1 < 0) then
    part1 = -part1
    area1 = -area1
  endif


  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flimb,dvdf*flimb)/ellipse_a(i_ell_a_p))),ngx)
  if (verbose >= v_debug) then
    print *,'partial: ',4,flimb,ngf
    print *,'partial: ',4,elimpar
  endif
  part2 = gauss2d(ngf,bright,0.0d0,flimb,glimposb,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area2 = gauss2d(ngf,unitfunc,0.0d0,flimb,glimposb,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area2 < 0) then
    part2 = -part2
    area2 = -area2
  endif

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*(flimb-flima),dvdf*(flimb-flima)) &
        /ellipse_a(i_ell_a_p))),ngx)
  if (verbose >= v_debug) then
    print *,'partial: ',5,flima,flimb,ngf
    print *,'partial: ',5,elimpar
  endif
  part3 = gauss2d(ngf,bright,flimb,flima,glimnega,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area3 = gauss2d(ngf,unitfunc,flimb,flima,glimnega,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area3 < 0) then
    part3 = -part3
    area3 = -area3
  endif

  eflux = (part1 + part2 + part3)
  earea = (area1 + area2 + area3)
endif 

if (verbose >= v_debug) then
  print *,'partial: eflux, earea = ',real(eflux),real(earea)
endif
if (earea /= 0.d0) then
  partial = eflux/earea
else
  partial = 0.d0
endif

end function partial

!------------------------------------------------------------------------------

double precision function double_partial(ellipse_a, ellipse_b, ngx, fpar, &
                                         nfpar, verbose)
! Returns the average surface brightness of ellipse_a in the two regions not
! covered by ellipse_b in the case where the ellipses intersect at four points.
implicit none
integer, intent(in) :: ngx, nfpar, verbose
!f2py integer, parameter :: n_ell_par = 14
double precision, intent(in) :: ellipse_a(n_ell_par), ellipse_b(n_ell_par)
double precision, intent(inout) :: fpar(nfpar)
!f2py intent(in,out) :: fpar

! Local variables
double precision :: um,vm
double precision :: dudf,dvdf,dudg,dvdg
double precision :: fa(2),fb(2),uv(2)
double precision :: xyqc(2), qline(4), tq(4),t_a, t_b
double precision :: flima, flimb
double precision :: earea,eflux,area1,flux1
double precision :: uv_intersect(2,4)
integer, parameter :: nelimpar=16
double precision :: elimpar(nelimpar)
integer  :: flags, verbose1, k(4), i1(2),i2(2),j, j1, j2, ngf
integer,parameter :: ngmin = 4 ! Minimum number of integration points

verbose1 = verbose_for_calls(verbose)

! Find intersection points of ellipses.

call ell_ell_intersect(ellipse_a, ellipse_b, verbose1, flags, uv_intersect)
if (.not.btest(flags, b_ell_four_intersects)) then
 print *,'partial: n_intersect /=  4'
 print *, ellipse_a
 print *, ellipse_b
 print *, flags
 stop
endif

if (verbose >= v_debug) then
  print *,'partial: u_intersect = ', uv_intersect(1,1:4)
  print *,'partial: v_intersect = ', uv_intersect(2,1:4)
endif

! Deal with intersection points in clockwise order, sorted by the angle to the
! x-axis measured from their centroid.
xyqc = sum(uv_intersect,dim=2)/4.d0
tq = atan2(uv_intersect(2,1:4)-xyqc(2),uv_intersect(1,1:4)-xyqc(1))
call heapsort(tq,k)

! To find the two pairs of intersection points that define the limits of the two
! integration regions, test which ellipse it intersected first by a line from
! the centroid of the quadrilateral through the midpoint of the first two
! intersection points in the angle-ordered list created above.
qline(1:2) = xyqc
qline(3) = 0.5d0*(uv_intersect(1,k(1))+uv_intersect(1,k(2))) - xyqc(1)
qline(4) = 0.5d0*(uv_intersect(2,k(1))+uv_intersect(2,k(2))) - xyqc(2)
t_a = maxval(ell_line_intersect(ellipse_a, qline))
t_b = maxval(ell_line_intersect(ellipse_b, qline))
if (t_a < t_b) then
  i1 = [k(2),k(1)]
  i2 = [k(3),k(4)]
else
  i1 = [k(1),k(3)]
  i2 = [k(2),k(4)]
endif

earea = 0
eflux = 0

do j=1,2
  j1 = i1(j)
  j2 = i2(j)
  ! Mid-point of intersection line
  ! This is the origin of the (f,g) coordinate system.
  ! The variable "f" runs perpendicular to the line of intersection.
  ! The variable "g" runs along the line of intersection.
  um = 0.5d0* (uv_intersect(1,j1)+uv_intersect(1,j2))
  vm = 0.5d0* (uv_intersect(2,j1)+uv_intersect(2,j2))
  if (verbose >= v_debug) print *,'partial: (um,vm) = ',um,vm 
  dudg = uv_intersect(1,j2) - uv_intersect(1,j1)
  dvdg = uv_intersect(2,j2) - uv_intersect(2,j1)
  dvdf = -dudg
  dudf = dvdg
  ! Parametric equation of line along the "f" axis in (u,v) coordinates.
  qline(1) = um
  qline(2) = vm
  qline(3) = dudf
  qline(4) = dvdf

  ! Intersection of "f" axis with each ellipse.
  fa = ell_line_intersect(ellipse_a, qline)
  if (fa(1) == -huge(0.d0))  then
    print *,'Error calling ell_line_intersect(ellipse_a, qline)'
    print *,ellipse_a
    print *,qline
    stop
  endif
  fb = ell_line_intersect(ellipse_b, qline)
  if (fb(1) == -huge(0.d0))  then
    print *,'Error calling ell_line_intersect(ellipse_b, qline)'
    print *,ellipse_b
    print *,qline
    stop
  endif
  uv(:) = [um + dudf*fa(1) ,  vm + dvdf*fa(1) ]
  if (abs(fa(1)) < abs(fa(2))) then
    flima = fa(1)
  else
    flima = fa(2)
  endif
  uv(:) = [um + dudf*fb(1) ,  vm + dvdf*fb(1)]
  if (abs(fb(1)) < abs(fb(2))) then
    flimb = fb(1)
  else
    flimb = fb(2)
  endif
  ! This is the transformation matrix from the (f,g) coordinate system to 
  ! the (s,t) coordinate system within bright.
  fpar(28) = um-ellipse_a(i_ell_x_c)
  fpar(29) = vm-ellipse_a(i_ell_y_c)
  fpar(30) = dudf
  fpar(31) = dudg
  fpar(32) = 1   ! Enable coordinate transformation

  elimpar(1) = um
  elimpar(2) = vm
  elimpar(3) = dudg
  elimpar(4) = dvdg
  elimpar(5:10) =  ellipse_a(i_ell_qcoeff)
  elimpar(11:16) =  ellipse_b(i_ell_qcoeff)

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flimb,dvdf*flimb)/ellipse_a(i_ell_a_p))),ngx)
  flux1 = gauss2d(ngx,bright,0.0d0,flimb,glimnegb,glimnega, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area1 = gauss2d(ngx,unitfunc,0.0d0,flimb,glimnegb,glimnega, &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area1 < 0) then
    flux1 = -flux1
    area1 = -area1
  endif
  eflux = eflux + flux1
  earea = earea + area1

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*flimb,dvdf*flimb)/ellipse_a(i_ell_a_p))),ngx)
  flux1 = gauss2d(ngx,bright,0.0d0,flimb,glimposb,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area1 = gauss2d(ngx,unitfunc,0.0d0,flimb,glimposb,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area1 < 0) then
    flux1 = -flux1
    area1 = -area1
  endif
  eflux = eflux + flux1
  earea = earea + area1

  ngf = min(max(ngmin, &
        nint(0.5d0*ngx*hypot(dudf*(flimb-flima),dvdf*(flimb-flima)) &
        /ellipse_a(i_ell_a_p))),ngx)
  flux1 = gauss2d(ngx,bright,flimb,flima,glimnega,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  area1 = gauss2d(ngx,unitfunc,flimb,flima,glimnega,glimposa,  &
          nelimpar,elimpar,nfpar,fpar,nymin=ngmin,nymax=ngx,verbose=verbose1)
  if (area1 < 0) then
    flux1 = -flux1
    area1 = -area1
  endif
  eflux = eflux + flux1
  earea = earea + area1

end do
if (earea /= 0.d0) then
  double_partial = eflux/earea
else
  double_partial = 0.d0
endif

end function double_partial

!------------------------------------------------------------------------------

double precision function glimnega(f, nelimpar, elimpar)
implicit none
double precision, intent(in) :: f
integer, intent(in)  :: nelimpar
double precision, intent(in) :: elimpar(nelimpar)
! Local variables
double precision :: g(2),dudg,dvdg,qline(4)
!f2py integer, parameter :: n_ell_par = 14
double precision :: dummy_ellipse(n_ell_par)
dudg = elimpar(3)
dvdg = elimpar(4)
qline(1) = elimpar(1) + dvdg*f
qline(2) = elimpar(2) - dudg*f
qline(3) = dudg
qline(4) = dvdg
dummy_ellipse(i_ell_qcoeff) = elimpar(5:10)
g(1:2) = ell_line_intersect(dummy_ellipse, qline)
if (g(1) == -huge(0.0d0) ) then
  print *,'glimnega: error finding limit'
  print *, real(qline)
  print *, f, elimpar
  glimnega  = bad_dble
  return
endif
if (g(1) < 0.0d0) then
  glimnega = g(1)
else
  glimnega = g(2)
endif
end function glimnega

!------------------------------------------------------------------------------

double precision function glimposa(f, nelimpar, elimpar)
implicit none
double precision, intent(in) :: f
integer, intent(in)  :: nelimpar
double precision, intent(in) :: elimpar(nelimpar)
! Local variables
double precision :: g(2),dudg,dvdg,qline(4)
!f2py integer, parameter :: n_ell_par = 14
double precision :: dummy_ellipse(n_ell_par)
dudg = elimpar(3)
dvdg = elimpar(4)
qline(1) = elimpar(1) + dvdg*f
qline(2) = elimpar(2) - dudg*f
qline(3) = dudg
qline(4) = dvdg
dummy_ellipse(i_ell_qcoeff) = elimpar(5:10)
g(1:2) = ell_line_intersect(dummy_ellipse, qline)
if (g(1) == -huge(0.0d0) ) then
  print *,'glimposa: error finding limit'
  print *, real(qline)
  print *, f, elimpar
  glimposa  = bad_dble
  return
endif
if (g(1) > 0.0d0) then
  glimposa = g(1)
else
  glimposa = g(2)
endif
end function glimposa

!------------------------------------------------------------------------------

double precision function glimnegb(f, nelimpar, elimpar)
implicit none
double precision, intent(in) :: f
integer, intent(in)  :: nelimpar
double precision, intent(in) :: elimpar(nelimpar)
! Local variables
double precision :: g(2),dudg,dvdg,qline(4)
!f2py integer, parameter :: n_ell_par = 14
double precision :: dummy_ellipse(n_ell_par)
dudg = elimpar(3)
dvdg = elimpar(4)
qline(1) = elimpar(1) + dvdg*f
qline(2) = elimpar(2) - dudg*f
qline(3) = dudg
qline(4) = dvdg
dummy_ellipse(i_ell_qcoeff) = elimpar(11:16)
g(1:2) = ell_line_intersect(dummy_ellipse, qline)
if (g(1) == -huge(0.0d0) ) then
  print *,'glimnegb: error finding limit'
  print *, real(qline)
  print *, f, elimpar
  glimnegb  = bad_dble
  return
endif
if (g(1) < 0.0d0) then
  glimnegb = g(1)
else
  glimnegb = g(2)
endif
end function glimnegb

!------------------------------------------------------------------------------

double precision function glimposb(f, nelimpar, elimpar)
implicit none
double precision, intent(in) :: f
integer, intent(in)  :: nelimpar
double precision, intent(in) :: elimpar(nelimpar)
! Local variables
double precision :: g(2),dudg,dvdg,qline(4)
!f2py integer, parameter :: n_ell_par = 14
double precision :: dummy_ellipse(n_ell_par)
dudg = elimpar(3)
dvdg = elimpar(4)
qline(1) = elimpar(1) + dvdg*f
qline(2) = elimpar(2) - dudg*f
qline(3) = dudg
qline(4) = dvdg
dummy_ellipse(i_ell_qcoeff) = elimpar(11:16)
g(1:2) = ell_line_intersect(dummy_ellipse, qline)
if (g(1) == -huge(0.0d0) ) then
  print *,'glimposb: error finding limit'
  print *, real(qline)
  print *, f, elimpar
  glimposb  = bad_dble
  return
endif
if (g(1) > 0.0d0) then
  glimposb = g(1)
else
  glimposb = g(2)
endif
end function glimposb

end module ellc
