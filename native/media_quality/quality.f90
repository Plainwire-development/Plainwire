module plainwire_quality
  use iso_c_binding, only: c_double, c_int
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
contains
  subroutine analyze(n, x, out) bind(C, name='pw_quality_analyze')
    integer(c_int), value :: n
    real(c_double), intent(in) :: x(9, n)
    real(c_double), intent(out) :: out(13)
    real(c_double) :: means(8), devs(8), slopes(8), vals(24), times(24)
    real(c_double) :: tmp, tm, denom, penalty, p95, cv, coverage
    integer :: counts(8), i, j, k, m, observed

    out = -1.0_c_double
    if (n < 1 .or. n > 24) return
    if (any(.not. ieee_is_finite(x))) return
    means = -1.0_c_double
    devs = 0.0_c_double
    slopes = -1000000000.0_c_double
    counts = 0
    do j = 1, 8
      m = 0
      do i = 1, n
        if (x(j + 1, i) < 0) cycle
        m = m + 1
        vals(m) = x(j + 1, i)
        times(m) = x(1, i)
      end do
      counts(j) = m
      if (m == 0) cycle
      means(j) = sum(vals(1:m)) / real(m, c_double)
      devs(j) = sqrt(sum((vals(1:m) - means(j))**2) / real(m, c_double))
      if (m >= 3) then
        tm = sum(times(1:m)) / real(m, c_double)
        denom = sum((times(1:m) - tm)**2)
        if (denom > 0) slopes(j) = 10 * sum((times(1:m)-tm)*(vals(1:m)-means(j))) / denom
      end if
      if (j == 2) then
        do i = 2, m
          tmp = vals(i)
          k = i - 1
          do while (k >= 1)
            if (vals(k) <= tmp) exit
            vals(k + 1) = vals(k)
            k = k - 1
          end do
          vals(k + 1) = tmp
        end do
        out(4) = vals(max(1, ceiling(0.95_c_double * m)))
      end if
    end do

    observed = count(counts(1:5) > 0)
    coverage = 100.0_c_double * observed / 5
    penalty = 0
    if (counts(1) > 0) penalty = penalty + min(35.0_c_double, means(1) * 5)
    if (counts(2) > 0) then
      p95 = out(4)
      penalty = penalty + min(15.0_c_double, max(0.0_c_double, p95 - 20) * 0.25_c_double)
    end if
    if (counts(3) > 0) penalty = penalty + min(20.0_c_double, max(0.0_c_double, means(3)-150) * 0.04_c_double)
    if (counts(4) > 0) penalty = penalty + min(30.0_c_double, means(4) * 3)
    if (counts(5) > 0) penalty = penalty + min(15.0_c_double, max(0.0_c_double, means(5)-80) * 0.10_c_double)
    if (observed >= 2 .and. n >= 3) out(1) = max(0.0_c_double, 100 - penalty)
    cv = 0
    if (counts(6) >= 3 .and. means(6) > 0) then
      cv = 100 * devs(6) / means(6)
      out(8) = cv
    end if
    if (counts(1) >= 3 .or. counts(2) >= 3) then
      out(2) = max(0.0_c_double, 100 - min(100.0_c_double, 3*devs(1) + 2*devs(2)))
    end if
    ! Bitrate variation is exposed separately: speech and silence naturally vary.
    ! It must not independently classify a quiet microphone as a bad network.
    out(3) = means(1)
    out(5) = means(3)
    out(6) = means(4)
    out(7) = means(5)
    out(9) = slopes(2)
    out(10) = slopes(1)
    out(11) = means(8)
    out(12) = coverage
    out(13) = n
  end subroutine analyze
end module plainwire_quality
