#include "cppdefs.h"
#ifdef TANGENT
      SUBROUTINE tl_initial (ng)
!
!svn $Id: tl_initial.F 2232 2012-01-03 18:55:20Z arango $
!================================================== Hernan G. Arango ===
!  Copyright (c) 2002-2012 The ROMS/TOMS Group                         !
!    Licensed under a MIT/X style license                              !
!    See License_ROMS.txt                                              !
!=======================================================================
!                                                                      !
!  This routine initializes all tangent linear model variables.        !
!                                                                      !
!=======================================================================
!
      USE mod_param
      USE mod_parallel
# ifdef BBL_MODEL_NOT_YET
      USE mod_bbl
# endif
# ifdef FOUR_DVAR
#  ifdef SOLVE3D
      USE mod_coupling
#  endif
      USE mod_fourdvar
# endif
      USE mod_grid
      USE mod_iounits
      USE mod_ncparam
      USE mod_ocean
      USE mod_scalars
      USE mod_stepping
!
      USE analytical_mod
# ifdef DISTRIBUTE
      USE distribute_mod, ONLY : mp_bcasti
# endif
# ifdef TLM_CHECK
      USE ini_adjust_mod, ONLY : tl_ini_perturb
# endif
      USE ini_hmixcoef_mod, ONLY : ini_hmixcoef
# ifdef IS4DVAR_SENSITIVITY
      USE ini_lanczos_mod, ONLY : ini_lanczos
# endif
      USE metrics_mod, ONLY : metrics
# ifdef ADJUST_BOUNDARY
      USE mod_boundary, ONLY : initialize_boundary
# endif
# if defined ADJUST_STFLUX || defined ADJUST_WSTRESS
      USE mod_forces, ONLY : initialize_forces
# endif
# if defined SENSITIVITY_4DVAR || \
     defined TL_W4DPSAS        || defined TL_W4DVAR  || \
     defined W4DPSAS           || defined W4DVAR
      USE tl_set_depth_mod, ONLY : tl_bath
# endif
# ifdef SOLVE3D
      USE set_depth_mod, ONLY : set_depth
      USE tl_set_depth_mod, ONLY : tl_set_depth
      USE tl_omega_mod, ONLY : tl_omega
      USE tl_rho_eos_mod, ONLY : tl_rho_eos
      USE tl_set_massflux_mod, ONLY : tl_set_massflux
# endif
      USE stiffness_mod, ONLY : stiffness
# ifdef WAVES_OCEAN
      USE ocean_coupler_mod, ONLY : waves_coupling
# endif
# ifdef MASKING
      USE set_masks_mod, ONLY : set_masks
# endif
# if defined PROPAGATOR || \
    (defined MASKING    && (defined READ_WATER || defined WRITE_WATER))
      USE wpoints_mod, ONLY : wpoints
# endif
!
      implicit none
!
!  Imported variable declarations.
!
      integer, intent(in) :: ng
!
!  Local variable declarations.
!
      logical :: update = .FALSE.

      integer :: LBi, UBi, LBj, UBj
      integer :: IniRec, InpRec, Tindex, subs, tile, thread, wrtRec
      integer :: Fcount

      integer :: my_numthreads
!
!=======================================================================
!   Initialize model variables.
!=======================================================================
!
      IF (Master) THEN
# if defined PERTURBATION
        WRITE (stdout,10) Nrun
 10     FORMAT (/,' <<<< Ensemble/Perturbation Run: ',i5.5,' >>>>',/)
# elif defined IS4DVAR    || defined SENSITIVITY_4DVAR || \
       defined TL_W4DPSAS || defined TL_W4DVAR         || \
       defined W4DPSAS    || defined W4DVAR
        WRITE (stdout,10) outer, inner
 10     FORMAT (/,' <<<< 4D Variational Data Assimilation, ',           &
     &          'Outer = ',i3.3, ', Inner = ',i3.3,' >>>>',/)
# endif
        WRITE (stdout,20) 'TL_INITIAL: Configuring and ',               &
     &                    'initializing tangent linear model ...'
 20     FORMAT (/,1x,a,a,/)
      END IF
!
!-----------------------------------------------------------------------
!  Initialize time stepping indices and counters.
!-----------------------------------------------------------------------
!
      iif(ng)=1
      indx1(ng)=1
      kstp(ng)=1
      krhs(ng)=1
      knew(ng)=1
      PREDICTOR_2D_STEP(ng)=.FALSE.
      synchro_flag(ng)=.TRUE.
      first_time(ng)=0
!
      iic(ng)=0
      nstp(ng)=1
      nrhs(ng)=1
      nnew(ng)=1
# ifdef FLOATS_NOT_YET
      nf(ng)=0
      nfp1(ng)=1
      nfm1(ng)=4
      nfm2(ng)=3
      nfm3(ng)=2
# endif
      IF (ANY(tl_VolCons(:,ng))) THEN
        tl_ubar_xs=0.0_r8
      END IF
      tdays(ng)=dstart
      time(ng)=tdays(ng)*day2sec
      ntstart(ng)=INT((time(ng)-dstart*day2sec)/dt(ng))+1
      ntend(ng)=ntimes(ng)
      ntfirst(ng)=ntstart(ng)
      CALL time_string (time(ng), time_code(ng))

      IniRec=nrrec(ng)
      Tindex=1

      LBi=LBOUND(GRID(ng)%h,DIM=1)
      UBi=UBOUND(GRID(ng)%h,DIM=1)
      LBj=LBOUND(GRID(ng)%h,DIM=2)
      UBj=UBOUND(GRID(ng)%h,DIM=2)

# ifdef PROFILE
!
!-----------------------------------------------------------------------
!  Start time wall clocks.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread) SHARED(numthreads)
      DO thread=0,numthreads-1
        CALL wclock_on (ng, iTLM, 2)
      END DO
!$OMP END PARALLEL DO
# endif

# if defined OPT_OBSERVATIONS
!
!-----------------------------------------------------------------------
!  Initialize.
!-----------------------------------------------------------------------
!
!  Set initial conditions time record to read.
!
       IniRec=1

# elif defined FOUR_DVAR || defined TLM_CHECK
!
!-----------------------------------------------------------------------
!  If variational data assimilation, reset several IO switches and
!  variables.
!-----------------------------------------------------------------------

#  ifndef IS4DVAR_SENSITIVITY
#   ifdef IS4DVAR
!
!  Set switch to create (TRUE) tangent linear initial conditions and
!  history NetCDF files or append (FALSE) to existing files. Then,
!  create tangent linear model initialization file and write zero
!  initial conditions for records 1 and 2.
!
      IF ((Nrun.eq.ERstr).and.(inner.eq.0)) THEN
        LdefITL(ng)=.TRUE.
        CALL tl_def_ini (ng)
        IF (exit_flag.ne.NoError) RETURN
        CALL tl_wrt_ini (ng, Tindex, 1)
        IF (exit_flag.ne.NoError) RETURN
        CALL tl_wrt_ini (ng, Tindex, 2)
        IF (exit_flag.ne.NoError) RETURN
      END IF
#   endif
#   ifndef WEAK_CONSTRAINT
!
!  Set switch to create tangent linear history file.
!
      IF (Nrun.eq.ERstr) THEN
        LdefTLM(ng)=.TRUE.
      END IF
#   endif
!
!  Set record to read from initial tangent linear NetCDF file.
!
      IniRec=ITL(ng)%Rindex

#   ifdef ADJUST_BOUNDARY
!
!  Initialize open boundary counter for storage arrays.
!
      OBCcount(ng)=0
#   endif
#   if defined ADJUST_STFLUX || defined ADJUST_WSTRESS
!
!  Initialize surface forcing counter for storage arrays.
!
      SFcount(ng)=0
#   endif
#   if !defined WEAK_CONSTRAINT
!
!  Reset tangent linear model history time record counters. These
!  counters are reset in every iteration pass. This file is created
!  on the first iteration pass.
!
      TLM(ng)%Rindex=0
      Fcount=TLM(ng)%Fcount
      TLM(ng)%Nrec(Fcount)=0
      LwrtTLM(ng)=.TRUE.
!
!  Insure that forward and history file names are the same. In 4DVar,
!  the forward solution is computed by the nonlinear model and stored
!  on HISNAME NetCDF file.
!
#    ifdef TLM_CHECK
      FWD(ng)%name=TRIM(HIS(ng)%base)//'.nc'
      FWD(ng)%ncid=-1
#    else
      FWD(ng)%name=HIS(ng)%name
      FWD(ng)%ncid=HIS(ng)%ncid
#    endif
#   endif
#  endif
#  ifdef OBSERVATIONS
!
!  Open observations NetCDF file and initialize various variables
!  needed for processing the nonlinear state solution at observation
!  locations.
!
      CALL obs_initial (ng, iTLM, .FALSE.)
      IF (exit_flag.ne.NoError) RETURN
#  endif
# endif
!
!=======================================================================
!  On first pass of ensemble run loop, initialize model configuration.
!=======================================================================
!
      IF (Nrun.eq.ERstr) THEN
!
!-----------------------------------------------------------------------
!  Set horizontal grid, bathymetry, and Land/Sea masking (if any).
!  Use analytical functions or read in from a grid NetCDF.
!-----------------------------------------------------------------------
!
# ifdef ANA_GRID
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_grid (ng, TILE, iTLM)
#  ifdef MASKING
            CALL ana_mask (ng, TILE, iTLM)
#  endif
          END DO
        END DO
!$OMP END PARALLEL DO
# else
        CALL get_grid (ng, iTLM)
#  ifdef DISTRIBUTE
        CALL mp_bcasti (ng, iTLM, exit_flag)
#  endif
        IF (exit_flag.ne.NoError) RETURN
# endif

# ifdef SOLVE3D
!
!-----------------------------------------------------------------------
!  Set vertical S-coordinate transformation function.
!-----------------------------------------------------------------------
!
        CALL set_scoord (ng)
# endif

# ifdef SOLVE3D
!
!-----------------------------------------------------------------------
!  Set barotropic time-steps average weighting function.
!-----------------------------------------------------------------------
!
        CALL set_weights (ng)
# endif
!
!-----------------------------------------------------------------------
!  Compute various metric term combinations.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL metrics (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
!
!-----------------------------------------------------------------------
!  If appropriate, set nudging coefficiests time scales.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_nudgcoef (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO

      END IF
!
!-----------------------------------------------------------------------
!  Initialize horizontal mixing coefficients.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL ini_hmixcoef (ng, TILE, iTLM)
        END DO
      END DO
!$OMP END PARALLEL DO

# if defined VISC_GRID || defined DIFF_GRID || defined SPONGE
!
!-----------------------------------------------------------------------
!  Set horizontal mixing coefficients. Rescale according to the local
!  grid size. If applicable, increases horizontal mixing in sponge
!  areas.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL ana_hmixcoef (ng, TILE, iTLM)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif
!
!=======================================================================
!  Initialize model state variables and forcing.  This part is
!  executed for each ensemble/perturbation/iteration pass.
!=======================================================================

# if defined FOUR_DVAR && !defined IS4DVAR_SENSITIVITY
#  if defined OPT_OBSERVATIONS || defined TLM_CHECK || \
      defined WEAK_CONSTRAINT
!
!  Clear tangent linear state variables.
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL initialize_ocean (ng, TILE, iTLM)
#   ifdef SOLVE3D
          CALL initialize_coupling (ng, TILE, 0)
#   endif
        END DO
      END DO
!$OMP END PARALLEL DO

#  else
#   ifndef WEAK_CONSTRAINT
!
!-----------------------------------------------------------------------
!  If first interation of the inner loop, clear all tangent linear
!  variables. In incrementatal 4DVAR, the tangent linear model is
!  started from rest on the first pass of the inner loop for each
!  outer loop iteration.
!-----------------------------------------------------------------------
!
      IF (inner.eq.0) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
#    ifdef ADJUST_BOUNDARY
            CALL initialize_boundary (ng, TILE, iTLM)
#    endif
#    if defined ADJUST_STFLUX || defined ADJUST_WSTRESS
            CALL initialize_forces (ng, TILE, iTLM)
#    endif
            CALL initialize_ocean (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
!
!  Rewrite tangent linear initial NetCDF (record 1) with zero initial
!  conditions since the model needs to be started from at the first
!  pass of the inner loop.
!
        IF (Nrun.gt.1) THEN
          wrtRec=1
          CALL tl_wrt_ini (ng, Tindex, wrtRec)
          IF (exit_flag.ne.NoError) RETURN
        END IF
      END IF
#   endif
#  endif
# endif

# if defined SOLVE3D && !defined INI_FILE
!
!-----------------------------------------------------------------------
!  If analytical initial conditions, compute initial time-evolving
!  depths with zero free-surface.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL set_depth (ng, TILE)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif

# if defined SENSITIVITY_4DVAR || \
     defined TL_W4DPSAS        || defined TL_W4DVAR || \
     defined W4DPSAS           || defined W4DVAR
!
!-----------------------------------------------------------------------
!  Initialize tangent linear bathymetry to zero.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL tl_bath (ng, TILE)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif
!
!-----------------------------------------------------------------------
!  Set tangent linear model state variables initial conditions.
!-----------------------------------------------------------------------

# ifdef ANA_INITIAL
!
!  Analytical initial conditions for momentum and active tracers.
!
      IF (nrrec(ng).eq.0) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_initial (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF
# endif

# if defined ANA_PASSIVE && defined SOLVE3D
!
!  Analytical initial conditions for inert passive tracers.
!
      IF (nrrec(ng).eq.0) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_passive (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF
# endif

# if defined ANA_BIOLOGY && defined SOLVE3D
!
!  Analytical initial conditions for biology.
!
      IF (nrrec(ng).eq.0) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_biology (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF
# endif

# if defined ANA_SEDIMENT_NOT_YET && defined SOLVE3D
!
!  Analytical initial conditions for sediment.
!
      IF (nrrec(ng).eq.0) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_sediment (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF
# endif

# ifdef IS4DVAR_SENSITIVITY
!
!  Initialize with the weighted sum of all Lanczos vectors computed
!  from the first outer loop of the IS4DVAR Lanczos algorithm.
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile,Tindex)                      &
!$OMP&            SHARED(numthreads,Lnew)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL ini_lanczos (ng, TILE, Lnew(ng), Tindex)
        END DO
      END DO
!$OMP END PARALLEL DO

# else
!
!  Read in initial conditions for initial or restart NetCDF file.
!
#  ifdef INI_FILE
      CALL get_state (ng, iTLM, 1, ITL(ng)%name, IniRec, Tindex)
      IF (exit_flag.ne.NoError) RETURN
#  else
      IF (nrrec(ng).ne.0) THEN
        CALL get_state (ng, iTLM, 1, ITL(ng)%name, IniRec, Tindex)
        IF (exit_flag.ne.NoError) RETURN
      END IF
#  endif
# endif

# if defined ANA_PERTURB && defined SANITY_CHECK
!
!-----------------------------------------------------------------------
!  Perturb tangent linear initial conditions with analitical
!  expressions.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL ana_perturb (ng, TILE, iTLM)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif

# ifdef TLM_CHECK
!
!-----------------------------------------------------------------------
!  Perturb tangent linear state variable according to the outer loop
!  iteration with the steepest descent direction of the gradient
!  (adjoint state).
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile,Tindex)                      &
!$OMP             SHARED(numthreads,Lnew)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL tl_ini_perturb (ng, TILE, Lnew(ng), Tindex)
        END DO
      END DO
!$OMP END PARALLEL DO
#  endif

# ifdef SOLVE3D
!!
!!----------------------------------------------------------------------
!!  Compute initial time-evolving depths.
!!----------------------------------------------------------------------
!!
!!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
!!    DO thread=0,numthreads-1
!!      subs=NtileX(ng)*NtileE(ng)/numthreads
!!      DO tile=subs*thread,subs*(thread+1)-1
!!        CALL tl_set_depth (ng, TILE)
!!      END DO
!!    END DO
!!$OMP END PARALLEL DO
!!
!!----------------------------------------------------------------------
!!  Compute initial horizontal mass fluxes, Hz*u/n and Hz*v/m.
!!----------------------------------------------------------------------
!!
!!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
!!    DO thread=0,numthreads-1
!!      subs=NtileX(ng)*NtileE(ng)/numthreads
!!      DO tile=subs*thread,subs*(thread+1)-1
!!        CALL tl_set_massflux (ng, TILE)
!!      END DO
!!    END DO
!!$OMP END PARALLEL DO
!!
!!----------------------------------------------------------------------
!!  Compute initial S-coordinates vertical velocity. Compute initial
!!  density anomaly from potential temperature and salinity via equation
!!  of state for seawater.  Also compute other equation of state related
!!  quatities.
!!----------------------------------------------------------------------
!!
!!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
!!    DO thread=0,numthreads-1
!!      subs=NtileX(ng)*NtileE(ng)/numthreads
!!      DO tile=subs*thread,subs*(thread+1)-1
!!        CALL tl_omega (ng, TILE)
!!        CALL tl_rho_eos (ng, TILE)
!!      END DO
!!    END DO
!!$OMP END PARALLEL DO
# endif
!
!-----------------------------------------------------------------------
!  Read in initial forcing, climatology and assimilation data from
!  input NetCDF files.  It loads the first relevant data record for
!  the time-interpolation between snapshots.
!-----------------------------------------------------------------------
!
      CALL close_inp (ng, iTLM)
# ifdef TIMELESS_DATA
      CALL tl_get_idata (ng)
# endif
      CALL tl_get_data (ng)
# ifdef DISTRIBUTE
      CALL mp_bcasti (ng, iTLM, exit_flag)
# endif
      IF (exit_flag.ne.NoError) RETURN

# ifdef MASKING
!
!-----------------------------------------------------------------------
!  Set internal I/O mask arrays.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1,+1
          CALL set_masks (ng, TILE, iTLM)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif

# if defined PROPAGATOR || \
    (defined MASKING    && (defined READ_WATER || defined WRITE_WATER ))
!
!-----------------------------------------------------------------------
!  Set variables associated with the processing water points and/or
!  size of packed state arrays.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1
          CALL wpoints (ng, TILE, iTLM)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif

# ifdef WEAK_CONSTRAINT
!
!-----------------------------------------------------------------------
!  If available, read in first TLM impulse forcing and its application
!  time. In true weak constraint applications, the impulse records
!  after the initial are associated with the model error and are
!  processed with different statistics. If there is only one (initial)
!  impulse forcing available, the assimilation tis similar to strong
!  constraint but in observation space.
!-----------------------------------------------------------------------
!
      IF (nADJ(ng).lt.ntimes(ng)) THEN
        IniRec=1
        CALL get_state (ng, 7, 7, TLF(ng)%name, IniRec, 1)
        IF (exit_flag.ne.NoError) RETURN
      END IF
# endif

# if defined ANA_DRAG && defined UV_DRAG_GRID
!
!-----------------------------------------------------------------------
!  Set analytical spatially varying bottom friction parameter.
!-----------------------------------------------------------------------
!
      IF (Nrun.eq.ERstr) THEN
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL ana_drag (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF
# endif
!
!-----------------------------------------------------------------------
!  Compute grid stiffness.
!-----------------------------------------------------------------------
!
      IF (Lstiffness) THEN
        Lstiffness=.FALSE.
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
        DO thread=0,numthreads-1
          subs=NtileX(ng)*NtileE(ng)/numthreads
          DO tile=subs*thread,subs*(thread+1)-1
            CALL stiffness (ng, TILE, iTLM)
          END DO
        END DO
!$OMP END PARALLEL DO
      END IF

# if defined FLOATS_NOT_YET || defined STATIONS
!
!-----------------------------------------------------------------------
!  If applicable, convert initial locations to fractional grid
!  coordinates.
!-----------------------------------------------------------------------
!
      CALL grid_coords (ng, iTLM)
# endif

# ifdef WAVES_OCEAN_NOT_YET
!
!-----------------------------------------------------------------------
!  Read in initial forcing from coupled wave model.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread,subs,tile) SHARED(numthreads)
      DO thread=0,numthreads-1
        subs=NtileX(ng)*NtileE(ng)/numthreads
        DO tile=subs*thread,subs*(thread+1)-1,+1
          CALL waves_coupling (ng, TILE)
        END DO
      END DO
!$OMP END PARALLEL DO
# endif
!
!-----------------------------------------------------------------------
!  Initialize time-stepping counter and clock.
!-----------------------------------------------------------------------
!
!  Subsract one time unit to avoid special case due to initialization
!  in the main time-stepping routine.
!
      iic(ng)=ntstart(ng)-1
      time(ng)=time(ng)-dt(ng)

# ifdef PROFILE
!
!-----------------------------------------------------------------------
!  Turn off initiialization time wall clock.
!-----------------------------------------------------------------------
!
!$OMP PARALLEL DO PRIVATE(thread) SHARED(numthreads)
      DO thread=0,numthreads-1
        CALL wclock_off (ng, iTLM, 2)
      END DO
!$OMP END PARALLEL DO
# endif
      RETURN
      END SUBROUTINE tl_initial
#else
      SUBROUTINE tl_initial
      RETURN
      END SUBROUTINE tl_initial
#endif
