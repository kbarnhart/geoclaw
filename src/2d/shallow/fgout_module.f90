module fgout_module

    implicit none
    save

    ! Container for fixed grid data, geometry and output settings
    type fgout_grid
        ! Grid data
        real(kind=8), pointer :: early(:,:,:)
        real(kind=8), pointer :: late(:,:,:)
        
        ! Geometry
        integer :: num_vars(2),mx,my,point_style,fgno,output_format
        real(kind=8) :: dx,dy,x_low,x_hi,y_low,y_hi
        
        ! Time Tracking and output types
        integer :: num_output,next_output_index
        real(kind=8) :: start_time,end_time,dt

        integer, allocatable :: output_frames(:)
        real(kind=8), allocatable :: output_times(:)
    end type fgout_grid    


    logical, private :: module_setup = .false.

    ! Fixed grid arrays and sizes
    integer :: FGOUT_num_grids
    type(fgout_grid), target, allocatable :: FGOUT_fgrids(:)
    real(kind=8) :: FGOUT_tcfmax
    real(kind=8), parameter :: FGOUT_ttol = 1.d-13 ! tolerance for times


contains
                        
    
    ! Setup routine that reads in the fixed grids data file and sets up the
    ! appropriate data structures
    
    subroutine set_fgout(rest,fname)

        use amr_module, only: parmunit, tstart_thisrun

        implicit none
        
        ! Subroutine arguments
        logical :: rest  ! restart?
        character(len=*), optional, intent(in) :: fname
        
        ! Local storage
        integer, parameter :: unit = 7
        integer :: i,k
        type(fgout_grid), pointer :: fg
        real(kind=8) :: ts
        

        if (.not.module_setup) then

            write(parmunit,*) ' '
            write(parmunit,*) '--------------------------------------------'
            write(parmunit,*) 'SETFGOUT:'
            write(parmunit,*) '-----------'

            ! Open data file
            if (present(fname)) then
                call opendatafile(unit,fname)
            else
                call opendatafile(unit,'fgout_grids.data')
            endif

            ! Read in data
            read(unit,'(i2)') FGOUT_num_grids
            write(parmunit,*) '  mfgrids = ',FGOUT_num_grids
            if (FGOUT_num_grids == 0) then
                write(parmunit,*) '  No fixed grids specified for output'
                return
            endif
            
            ! Allocate fixed grids (not the data yet though)
            allocate(FGOUT_fgrids(FGOUT_num_grids))

            ! Read in data for each fixed grid
            do i=1,FGOUT_num_grids
                fg => FGOUT_fgrids(i)
                ! Read in this grid's data
                read(unit,*) fg%fgno
                read(unit,*) fg%start_time
                read(unit,*) fg%end_time
                read(unit,*) fg%num_output
                read(unit,*) fg%point_style
                read(unit,*) fg%output_format
                read(unit,*) fg%mx, fg%my
                read(unit,*) fg%x_low, fg%y_low
                read(unit,*) fg%x_hi, fg%y_hi
                
                allocate(fg%output_times(fg%num_output))
                allocate(fg%output_frames(fg%num_output))
                
                ! Initialize next_output_index
                ! (might be reset below in case of a restart)
                fg%next_output_index = 1
                   
                if (fg%point_style .ne. 2) then
                    print *, 'set_fgout: ERROR, unrecognized point_style = ',\
                          fg%point_style
                endif
                    
               ! Setup data for this grid
               ! Set dtfg (the timestep length between outputs) for each grid
               if (fg%end_time <= fg%start_time) then
                   if (fg%num_output > 1) then 
                      print *,'set_fgout: ERROR for fixed grid', i
                      print *,'start_time <= end_time yet num_output > 1'
                      print *,'set end_time > start_time or set num_output = 1'
                      stop
                   else
                       fg%dt = 0.d0
                   endif
               else
                   if (fg%num_output < 2) then
                       print *,'set_fgout: ERROR for fixed grid', i
                       print *,'end_time > start_time, yet num_output = 1'
                       print *,'set num_output > 2'
                       stop
                   else
                       fg%dt = (fg%end_time  - fg%start_time) &
                                           / (fg%num_output - 1)
                       do k=1,fg%num_output
                           fg%output_times(k) = fg%start_time + (k-1)*fg%dt
                           if (rest) then
                               ! don't write initial time or earlier
                               ts = tstart_thisrun*(1+FGOUT_ttol)
                           else
                               ! do write initial time
                               ts = tstart_thisrun*(1-FGOUT_ttol)
                           endif
                               
                           if (fg%output_times(k) < ts) then
                                ! will not output this time in this run
                                ! (might have already be done when restarting)
                                fg%output_frames(k) = -2
                                fg%next_output_index = k+1
                           else
                                ! will be reset to frameno when this is written
                                fg%output_frames(k) = -1
                           endif
                       enddo
                   endif
                endif



                ! Set spatial intervals dx and dy on each grid
                if (fg%mx > 1) then
                   !fg%dx = (fg%x_hi - fg%x_low) / (fg%mx - 1) ! points
                   fg%dx = (fg%x_hi - fg%x_low) / fg%mx   ! cells
                else if (fg%mx == 1) then
                   fg%dx = 0.d0
                else
                     print *,'set_fgout: ERROR for fixed grid', i
                     print *,'x grid points mx <= 0, set mx >= 1'
                endif

                if (fg%my > 1) then
                    !fg%dy = (fg%y_hi - fg%y_low) / (fg%my - 1) ! points
                    fg%dy = (fg%y_hi - fg%y_low) / fg%my  ! cells
                else if (fg%my == 1) then
                    fg%dy = 0.d0
                else
                    print *,'set_fgout: ERROR for fixed grid', i
                    print *,'y grid points my <= 0, set my >= 1'
                endif 
           
                ! set the number of variables stored for each grid
                ! this should be (the number of variables you want to write out + 1)
                fg%num_vars(1) = 6
                
                ! Allocate new fixed grid data array
                allocate(fg%early(fg%num_vars(1), fg%mx,fg%my))
                fg%early = nan()
                
                allocate(fg%late(fg%num_vars(1), fg%mx,fg%my))
                fg%late = nan()
                
           enddo
           close(unit)
           
           FGOUT_tcfmax=-1.d16

           module_setup = .true.
        end if

    end subroutine set_fgout
    
    
    !=====================FGOUT_INTERP=======================================
    ! This routine interpolates q and aux on a computational grid
    ! to an fgout grid not necessarily aligned with the computational grid
    ! using bilinear interpolation defined on computational grid
    !=======================================================================
    subroutine fgout_interp(fgrid_type,fgrid, &
                            t,q,meqn,mxc,myc,mbc,dxc,dyc,xlowc,ylowc, &
                            maux,aux)
    
        use geoclaw_module, only: dry_tolerance  
        implicit none
    
        ! Subroutine arguments
        integer, intent(in) :: fgrid_type
        type(fgout_grid), intent(inout) :: fgrid
        integer, intent(in) :: meqn,mxc,myc,mbc,maux
        real(kind=8), intent(in) :: t,dxc,dyc,xlowc,ylowc
        real(kind=8), intent(in) :: q(meqn,1-mbc:mxc+mbc,1-mbc:myc+mbc)
        real(kind=8), intent(in) :: aux(maux,1-mbc:mxc+mbc,1-mbc:myc+mbc)
    
        integer, parameter :: method = 0
        
        ! Indices
        integer :: ifg,jfg,m,ic1,ic2,jc1,jc2
        integer :: bathy_index,eta_index

        ! Tolerances
        real(kind=8) :: total_depth,depth_indicator,nan_check

        ! Geometry
        real(kind=8) :: xfg,yfg,xc1,xc2,yc1,yc2,xhic,yhic
        real(kind=8) :: geometry(4)
        
        real(kind=8) :: points(2,2), eta_tmp
        
        ! Work arrays for eta interpolation
        real(kind=8) :: eta(2,2),h(2,2)
        
        
        ! Alias to data in fixed grid
        integer :: num_vars
        real(kind=8), pointer :: fg_data(:,:,:)
        
        
        ! Setup aliases for specific fixed grid
        if (fgrid_type == 1) then
            num_vars = fgrid%num_vars(1)
            fg_data => fgrid%early
        else if (fgrid_type == 2) then
            num_vars = fgrid%num_vars(1)
            fg_data => fgrid%late
        else
            write(6,*) '*** Unexpected fgrid_type = ', fgrid_type
            stop
            ! fgrid_type==3 is deprecated, use fgmax grids instead
        endif
            
        xhic = xlowc + dxc*mxc  
        yhic = ylowc + dyc*myc    
        
        ! Find indices of various quantities in the fgrid arrays
        bathy_index = meqn + 1
        eta_index = meqn + 2
    
        !write(59,*) '+++ ifg,jfg,eta,geometry at t = ',t
    
        ! Primary interpolation loops 
        do ifg=1,fgrid%mx
            !xfg=fgrid%x_low + (ifg-1)*fgrid%dx      ! points
            xfg=fgrid%x_low + (ifg-0.5d0)*fgrid%dx   ! cell centers
            do jfg=1,fgrid%my
                !yfg=fgrid%y_low + (jfg-1)*fgrid%dy      ! points
                yfg=fgrid%y_low + (jfg-0.5d0)*fgrid%dy   ! cell centers
    
                ! Check to see if this coordinate is inside of this grid
                if (.not.((xfg < xlowc.or.xfg > xhic).or.(yfg < ylowc.or.yfg > yhic))) then
    
                    ! find where xfg,yfg is in the computational grid and compute the indices
                    ! and relevant coordinates of each corner
                    ic1 = int((xfg-(xlowc+0.5d0*dxc))/(dxc))+1
                    jc1 = int((yfg-(ylowc+0.5d0*dyc))/(dyc))+1
                    if (ic1.eq.mxc) ic1=mxc-1
                    if (jc1.eq.myc) jc1=myc-1 
                    ic2 = ic1 + 1
                    jc2 = jc1 + 1
                        
                    xc1 = xlowc + dxc * (ic1 - 0.5d0)
                    yc1 = ylowc + dyc * (jc1 - 0.5d0)
                    xc2 = xlowc + dxc * (ic2 - 0.5d0)
                    yc2 = ylowc + dyc * (jc2 - 0.5d0)
         
                    if (method == 1) then
                        ! Calculate geometry of interpolant
                        ! interpolate bilinear used to interpolate to xfg,yfg
                        ! define constant parts of bilinear
                        geometry = [(xfg - xc1) / dxc, &
                                    (yfg - yc1) / dyc, &
                                    (xfg - xc1) * (yfg - yc1) / (dxc*dyc), &
                                    1.d0]
                    endif
        
                    ! Interpolate for all conserved quantities and bathymetry
                    forall (m=1:meqn)
                        fg_data(m,ifg,jfg) = &
                            interpolate(q(m,ic1:ic2,jc1:jc2), geometry,method) 
                            !interpolate([[q(m,ic1,jc1),q(m,ic1,jc2)], &
                            !            [q(m,ic2,jc1),q(m,ic2,jc2)]], geometry)
                    end forall

                    
                    fg_data(bathy_index,ifg,jfg) = & 
                            interpolate(aux(1,ic1:ic2,jc1:jc2),geometry,method)

                    if (.false.) then
                        write(6,*) '+++ yfg,geometry(2) = ',yfg,geometry(2)
                        write(6,*) '+++ xfg,xc1,xc2,geometry(1): ', &
                                    xfg,xc1,xc2,geometry(1)
                        write(6,*) '+++ B11,B21: ', aux(1,ic1,jc1),aux(1,ic2,jc1)
                        write(6,*) '+++ B12,B22: ', aux(1,ic1,jc2),aux(1,ic2,jc2)
                        write(6,*) '+++ fg_data = ',fg_data(bathy_index,ifg,jfg)
                        write(6,*) '+++ points(2,1) = ',points(2,1)
                        write(6,*) '+++ '
                    endif
                    
                    ! surface eta = h + B:
                    
                    if (method == 0) then
                        ! for pw constant we take B, h, eta from same cell,
                        ! so setting eta = h+B should be fine even near shore:
                        fg_data(eta_index,ifg,jfg) = fg_data(1,ifg,jfg) &
                                + fg_data(bathy_index,ifg,jfg)
                                
                        ! tests for debugging:
                        
                        if ((fg_data(1,ifg,jfg) > 0) .and. &
                            (fg_data(eta_index,ifg,jfg) > 10.d0)) then
                            write(6,*) '*** unexpected eta = ',fg_data(eta_index,ifg,jfg)
                            write(6,*) '*** ifg, jfg: ',ifg,jfg
                        endif
                            
                        eta = q(1,ic1:ic2,jc1:jc2) + aux(1,ic1:ic2,jc1:jc2)
                        eta_tmp = interpolate(eta,geometry,method)
                        if (fg_data(eta_index,ifg,jfg) .ne. eta_tmp) then
                            write(6,*) '*** unexpected eta_tmp = ',eta_tmp
                            write(6,*) '***    fg_data(eta_index,ifg,jfg) = ', &
                                    fg_data(eta_index,ifg,jfg)
                        endif
                        
                    else if (method == 1) then
                        ! method==1 we are doing pw bilinear and there may
                        ! be a problem interpolating each separately
                        ! NEED TO FIX
                        eta = q(1,ic1:ic2,jc1:jc2) + aux(1,ic1:ic2,jc1:jc2)
                        fg_data(eta_index,ifg,jfg) = interpolate(eta,geometry,method)
                        continue
                    endif
                                                            
                    if (.false.) then
                        write(6,*) '+++ fg_data_eta = ',fg_data(eta_index,ifg,jfg)
                        write(6,*) '+++ fg_data_h = ',fg_data(1,ifg,jfg)
                    endif
                    
                    ! save the time this fgout point was computed:
                    fg_data(num_vars,ifg,jfg) = t
                    
                    !write(59,*) '+++',ifg,jfg
                    !write(59,*) eta
                    !write(59,*) geometry

                    
                endif ! if fgout point is on this grid
            enddo ! fgout y-coordinate loop
        enddo ! fgout x-coordinte loop
    
    end subroutine fgout_interp
    

    !================ fgout_write ==========================================
    ! This routine interpolates in time and then outputs a grid at
    ! time=out_time
    !
    ! files now have the same format as frames produced by outval
    !=======================================================================
    subroutine fgout_write(fgrid,out_time,out_index)

        implicit none
        
        ! Subroutine arguments
        type(fgout_grid), intent(inout) :: fgrid
        real(kind=8), intent(in) :: out_time
        integer, intent(in) :: out_index
              
        ! I/O
        integer, parameter :: unit = 87
        character(len=15) :: fg_filename
        character(len=4) :: cfgno, cframeno
        integer :: grid_number,ipos,idigit,out_number,columns
        integer :: ifg,ifg1, iframe,iframe1
        
        ! Output format strings 
        ! These are now the same as in outval for frame data, for compatibility
        ! For fgout grids there is only a single grid (ngrids=1)
        ! and we set AMR_level=0, naux=0, nghost=0 (so no extra cells in binary)
        
        character(len=*), parameter :: header_format =                         &
                                    "(i6,'                 grid_number',/," // &
                                     "i6,'                 AMR_level',/,"   // &
                                     "i6,'                 mx',/,"          // &
                                     "i6,'                 my',/"           // &
                                     "e26.16,'    xlow', /, "               // &
                                     "e26.16,'    ylow', /,"                // &
                                     "e26.16,'    dx', /,"                  // &
                                     "e26.16,'    dy',/)"
                                     
        character(len=*), parameter :: t_file_format = "(e18.8,'    time', /," // &
                                           "i6,'                 meqn'/,"   // &
                                           "i6,'                 ngrids'/," // &
                                           "i6,'                 naux'/,"   // &
                                           "i6,'                 ndim'/,"   // &
                                           "i6,'                 nghost'/,/)"
        
        ! Other locals
        integer :: i,j,m
        real(kind=8) :: t0,tf,tau, qaug(6)
        real(kind=8), allocatable :: qeta(:,:,:)
        real(kind=8) :: h_early,h_late,topo_early,topo_late
        
        allocate(qeta(4, fgrid%mx, fgrid%my))  ! to store h,hu,hv,eta
        
        
        ! Interpolate the grid in time, to the output time, using 
        ! the solution in fgrid1 and fgrid2, which represent the 
        ! solution on the fixed grid at the two nearest computational times
        do j=1,fgrid%my
            do i=1,fgrid%mx
                ! Fetch times for interpolation, this is done per grid point 
                ! since each grid point may come from a different source
                t0 = fgrid%early(fgrid%num_vars(1),i,j)
                tf = fgrid%late(fgrid%num_vars(1),i,j)
                tau = (out_time - t0) / (tf - t0)
                
                ! Check for small numbers
                forall(m=1:fgrid%num_vars(1)-1,abs(fgrid%early(m,i,j)) < 1d-90)
                    fgrid%early(m,i,j) = 0.d0
                end forall
                forall(m=1:fgrid%num_vars(1)-1,abs(fgrid%late(m,i,j)) < 1d-90)
                    fgrid%late(m,i,j) = 0.d0
                end forall
                
                ! no interpolation in time, use soln from full step:
                qaug = fgrid%late(:,i,j)
                
                ! note that CFL condition ==> waves can't move more than 1
                ! cell per time step on each level, so solution from nearest
                ! full step should be correct to within a cell width
                
                if (.false.) then
                    ! interpolate in time:
                    qaug = (1.d0-tau)*fgrid%early(:,i,j) + tau*fgrid%late(:,i,j)
                    
                    !write(6,*) '+++ tau, early, late: ',tau,fgrid%early(:,i,j),fgrid%late(:,i,j)
                    
                    ! if resolution changed between early and late time, may be
                    ! problems near shore when interpolating B, h, eta separately
                    if (qaug(1) > 0.d0) then
                        topo_early = fgrid%early(4,i,j)
                        topo_late = fgrid%late(4,i,j)
                        if (topo_early .ne. topo_late) then
                            h_early = fgrid%early(1,i,j)
                            h_late = fgrid%late(1,i,j)
                            if ((h_early == 0.d0) .xor. (h_late == 0.d0)) then
                                qaug = fgrid%early(:,i,j) ! revert to early values
                                write(6,*) '+++ reverting to early values at i,j, t0: ', i,j,t0
                                write(6,*) '+++ topo_early, topo_late: ',topo_early, topo_late
                            endif
                        endif
                    endif
                endif
                
                ! Output the conserved quantities and eta value
                qeta(1,i,j) = qaug(1)  ! h
                qeta(2,i,j) = qaug(2)  ! hu
                qeta(3,i,j) = qaug(3)  ! hv
                qeta(4,i,j) = qaug(5)  ! eta
                
                if ((qaug(1)>0.d0) .and. (qaug(5)>10.d0)) then
                    write(6,*) '*** unexpected i,j,qaug(5) = ',i,j,qaug(5)
                endif

            enddo
        enddo


        ! Make the file names and open output files
        cfgno = '0000'
        ifg = fgrid%fgno
        ifg1 = ifg
        do ipos=4,1,-1
            idigit = mod(ifg1,10)
            cfgno(ipos:ipos) = char(ichar('0') + idigit)
            ifg1 = ifg1/10
            enddo

        cframeno = '0000'
        iframe = out_index
        iframe1 = iframe
        do ipos=4,1,-1
            idigit = mod(iframe1,10)
            cframeno(ipos:ipos) = char(ichar('0') + idigit)
            iframe1 = iframe1/10
            enddo
            
        fg_filename = 'fgout' // cfgno // '.q' // cframeno 

        open(unit,file=fg_filename,status='unknown',form='formatted')

        ! Determine number of columns that will be written out
        columns = fgrid%num_vars(1) - 1
        if (fgrid%num_vars(2) > 1) then
           columns = columns + 2
        endif
        
        !write(6,*) '+++ fgout out_time = ',out_time
        !write(6,*) '+++ fgrid%num_vars: ',fgrid%num_vars(1),fgrid%num_vars(2)
        
        ! Write out header in .q file:
        !write(unit,header_format) out_time,fgrid%mx,fgrid%my, &
        !     fgrid%x_low,fgrid%y_low, fgrid%x_hi,fgrid%y_hi, columns

        write(unit,header_format) fgrid%fgno, 0, fgrid%mx,fgrid%my, &
            fgrid%x_low,fgrid%y_low, fgrid%dx, fgrid%dy
            
        if (fgrid%output_format == 1) then
            ! ascii output added to .q file:
            do j=1,fgrid%my
                do i=1,fgrid%mx
                    write(unit, "(50e26.16)") qeta(1,i,j),qeta(2,i,j), &
                                qeta(3,i,j),qeta(4,i,j)
                enddo
                write(unit,*) ' '  ! blank line required between rows
            enddo
        endif  
        
        close(unit)
        
        if (fgrid%output_format == 3) then
            ! binary output goes in .b file:
            fg_filename = 'fgout' // cfgno // '.b' // cframeno 
            open(unit=unit, file=fg_filename, status="unknown",    &
                 access='stream')
            write(unit) qeta
            close(unit)
        endif
        
        deallocate(qeta)

        ! time info .t file:
        fg_filename = 'fgout' // cfgno // '.t' // cframeno 
        open(unit=unit, file=fg_filename, status='unknown', form='formatted')
        ! time, num_eqn+1, num_grids, num_aux, num_dim, num_ghost:
        write(unit, t_file_format) out_time, 4, 1, 0, 2, 0
        close(unit)
        
        print "(a,i4,a,i4,a,e18.8)",'Writing fgout grid #',fgrid%fgno, &
              '  frame ',out_index,' at time =',out_time
      
        ! Index into qeta for binary output
        ! Note that this implicitly assumes that we are outputting only h, hu, hv
        ! and will not output more (change num_eqn parameter above)
        
    end subroutine fgout_write
              
    
    ! =========================================================================
    ! Utility functions for this module
    ! Returns back a NaN
    real(kind=8) function nan()
        real(kind=8) dnan
        integer inan(2)
        equivalence (dnan,inan)
        inan(1)=2147483647
        inan(2)=2147483647
        nan=dnan
    end function nan
    
    ! Interpolation function (in space)
    ! Given 4 points (points) and geometry from x,y,and cross terms
    real(kind=8) pure function interpolate(points,geometry,method) result(interpolant)
                            
        implicit none
                                
        ! Function signature
        real(kind=8), intent(in) :: points(2,2)
        real(kind=8), intent(in) :: geometry(4)
        integer, intent(in) :: method
        integer :: icell, jcell
        
        if (method == 0) then                   
            ! pw constant: value from cell fgmax point lies in
            if (geometry(1) < 0.5d0) then
                icell = 1
            else
                icell = 2
            endif
            if (geometry(2) < 0.5d0) then
                jcell = 1
            else
                jcell = 2
            endif   
            interpolant = points(icell,jcell)
        else if (method == 1) then
            ! pw bilinear
            ! This is set up as a dot product between the approrpriate terms in 
            ! the input data.  This routine could be vectorized or a BLAS routine
            ! used instead of the intrinsics to ensure that the fastest routine
            ! possible is being used
            interpolant = sum([points(2,1)-points(1,1), &
                           points(1,2)-points(1,1), &
                           points(1,1) + points(2,2) - (points(2,1) + points(1,2)), &
                           points(1,1)] * geometry)
        endif
    end function interpolate
    
    ! Interpolation function in time
    pure function interpolate_time(num_vars,early,late,tau) result(interpolant)
        
        implicit none
        
        ! Input arguments
        integer, intent(in) :: num_vars
        real(kind=8), intent(in) :: early(num_vars),late(num_vars),tau
        
        ! Return value
        real(kind=8) :: interpolant(num_vars)

        interpolant = (1.d0 - tau) * early(:) + tau * late(:)

    end function interpolate_time
    

end module fgout_module
