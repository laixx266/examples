! md_npt_lj.f90
! Molecular dynamics, NPT ensemble, Lennard-Jones atoms
PROGRAM md_npt_lj

  ! TODO (MPA) convert this NVE program to NPT
dt2 = dt / 2.0
g = 3.0*(n-1.0)
p_eta = p_eta + ( sum(p**2/m) - g*temperature ) * dt2 ! U4
p     = p * exp(-(p_eta/Q)*dt2)                       ! U3
eta   = eta + (p_eta/Q)*dt2                           ! U3
p     = p + f * dt2                                   ! U2
r     = r + (p/m) * dt                                ! U1
call force
p     = p + f * dt2                                   ! U2
eta   = eta + (p_eta/Q)*dt2                           ! U3
p     = p * exp(-(p_eta/Q)*dt2)                       ! U3
p_eta = p_eta + ( sum(p**2/m) - g*temperature ) * dt2 ! U4

  USE, INTRINSIC :: iso_fortran_env, ONLY : input_unit, output_unit, error_unit, iostat_end, iostat_eor
  USE utility_module, ONLY : read_cnf_atoms, write_cnf_atoms, time_stamp, &
       &                     run_begin, run_end, blk_begin, blk_end, blk_add
  USE md_lj_module,   ONLY : initialize, finalize, force, r, v, f, n, energy_lrc
  IMPLICIT NONE

  ! Takes in a configuration of atoms (positions, velocities)
  ! Cubic periodic boundary conditions
  ! Conducts molecular dynamics using velocity Verlet algorithm
  ! Uses no special neighbour lists

  ! Reads several variables and options from standard input using a namelist nml
  ! Leave namelist empty to accept supplied defaults

  ! Box is taken to be of unit length during the dynamics
  ! However, input configuration, output configuration,
  ! most calculations, and all results 
  ! are given in LJ units sigma = 1, epsilon = 1, mass = 1

  ! Most important variables
  REAL :: sigma       ! atomic diameter (in units where box=1)
  REAL :: box         ! box length (in units where sigma=1)
  REAL :: density     ! reduced density n*sigma**3/box**3
  REAL :: dt          ! time step
  REAL :: r_cut       ! potential cutoff distance
  REAL :: pot         ! total potential energy
  REAL :: pot_sh      ! total shifted potential energy
  REAL :: kin         ! total kinetic energy
  REAL :: vir         ! total virial
  REAL :: pressure    ! pressure (LJ sigma=1 units, to be averaged)
  REAL :: temperature ! temperature (LJ sigma=1 units, to be averaged)
  REAL :: energy      ! total energy per atom (LJ sigma=1 units, to be averaged)
  REAL :: energy_sh   ! total shifted energy per atom (LJ sigma=1 units, to be averaged)

  INTEGER :: blk, stp, nstep, nblock, ioerr
  REAL    :: pot_lrc, vir_lrc

  CHARACTER(len=4), PARAMETER :: cnf_prefix = 'cnf.'
  CHARACTER(len=3), PARAMETER :: inp_tag = 'inp', out_tag = 'out'
  CHARACTER(len=3)            :: sav_tag = 'sav' ! may be overwritten with block number

  NAMELIST /nml/ nblock, nstep, r_cut, dt

  WRITE ( unit=output_unit, fmt='(a)' ) 'md_nve_lj'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Molecular dynamics, constant-NVE, Lennard-Jones'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Results in units epsilon = sigma = mass = 1'
  CALL time_stamp ( output_unit )

  ! Set sensible default run parameters for testing
  nblock      = 10
  nstep       = 1000
  r_cut       = 2.5
  dt          = 0.005

  READ ( unit=input_unit, nml=nml, iostat=ioerr )
  IF ( ioerr /= 0 ) THEN
     WRITE ( unit=error_unit, fmt='(a,i15)') 'Error reading namelist nml from standard input', ioerr
     IF ( ioerr == iostat_eor ) WRITE ( unit=error_unit, fmt='(a)') 'End of record'
     IF ( ioerr == iostat_end ) WRITE ( unit=error_unit, fmt='(a)') 'End of file'
     STOP 'Error in md_nve_lj'
  END IF
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of blocks',          nblock
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of steps per block', nstep
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Potential cutoff distance', r_cut
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Time step',                 dt

  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box ) ! First call is just to get n and box
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of particles',  n
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Box (in sigma units)', box
  sigma = 1.0
  density = REAL(n) * ( sigma / box ) ** 3
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Reduced density', density

  ! Convert run and potential parameters to box units
  sigma  = sigma / box
  r_cut  = r_cut / box
  dt     = dt / box
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'sigma  (in box units)', sigma
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'r_cut  (in box units)', r_cut
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'dt     (in box units)', dt
  IF ( r_cut > 0.5  ) THEN
     WRITE ( unit=error_unit, fmt='(a,f15.5)') 'r_cut too large ', r_cut
     STOP 'Error in md_nve_lj'
  END IF

  CALL initialize ( r_cut )

  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box, r, v ) ! Second call gets r and v

  ! Convert to box units
  r(:,:) = r(:,:) / box
  r(:,:) = r(:,:) - ANINT ( r(:,:) ) ! Periodic boundaries

  CALL force ( sigma, r_cut, pot, pot_sh, vir )
  CALL energy_lrc ( n, sigma, r_cut, pot_lrc, vir_lrc )
  pot         = pot + pot_lrc
  vir         = vir + vir_lrc
  kin         = 0.5*SUM(v**2)
  energy      = ( pot + kin ) / REAL ( n )
  energy_sh   = ( pot_sh + kin ) / REAL ( n )
  temperature = 2.0 * kin / REAL ( 3*(n-1) )
  pressure    = density * temperature + vir / box**3
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial total energy (sigma units)',   energy
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial shifted energy (sigma units)', energy_sh
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial temperature (sigma units)',    temperature
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial pressure (sigma units)',       pressure

  CALL run_begin ( [ CHARACTER(len=15) :: 'Energy', 'Shifted Energy', 'Temperature', 'Pressure' ] )

  DO blk = 1, nblock ! Begin loop over blocks

     CALL blk_begin

     DO stp = 1, nstep ! Begin loop over steps

        ! Velocity Verlet algorithm
        v(:,:) = v(:,:) + 0.5 * dt * f(:,:)           ! Kick half-step
        r(:,:) = r(:,:) + dt * v(:,:)                 ! Drift step
        r(:,:) = r(:,:) - ANINT ( r(:,:) )            ! Periodic boundaries
        CALL force ( sigma, r_cut, pot, pot_sh, vir ) ! Force evaluation
        v(:,:) = v(:,:) + 0.5 * dt * f(:,:)           ! Kick half-step

        CALL energy_lrc ( n, sigma, r_cut, pot_lrc, vir_lrc )
        pot         = pot + pot_lrc
        vir         = vir + vir_lrc
        kin         = 0.5*SUM(v**2)
        energy      = ( pot + kin ) / REAL ( n )
        energy_sh   = ( pot_sh + kin ) / REAL ( n )
        temperature = 2.0 * kin / REAL ( 3*(n-1) )
        pressure    = density * temperature + vir / box**3

        ! Calculate all variables for this step
        CALL blk_add ( [energy,energy_sh,temperature,pressure] )

     END DO ! End loop over steps

     CALL blk_end ( blk, output_unit )
     IF ( nblock < 1000 ) WRITE(sav_tag,'(i3.3)') blk               ! number configuration by block
     CALL write_cnf_atoms ( cnf_prefix//sav_tag, n, box, r*box, v ) ! save configuration

  END DO ! End loop over blocks

  CALL run_end ( output_unit )

  CALL force ( sigma, r_cut, pot, pot_sh, vir )
  CALL energy_lrc ( n, sigma, r_cut, pot_lrc, vir_lrc )
  pot         = pot + pot_lrc
  vir         = vir + vir_lrc
  kin         = 0.5*SUM(v**2)
  energy      = ( pot + kin ) / REAL ( n )
  energy_sh   = ( pot_sh + kin ) / REAL ( n )
  temperature = 2.0 * kin / REAL ( 3*(n-1) )
  pressure    = density * temperature + vir / box**3
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Final total energy (sigma units)',   energy
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Final shifted energy (sigma units)', energy_sh
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Final temperature (sigma units)',    temperature
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Final pressure (sigma units)',       pressure
  CALL time_stamp ( output_unit )

  CALL write_cnf_atoms ( cnf_prefix//out_tag, n, box, r*box, v )

  CALL finalize

END PROGRAM md_npt_lj

