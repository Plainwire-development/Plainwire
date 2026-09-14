module plainwire_quality
  use iso_c_binding, only: c_double, c_int
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  private
  public :: analyze
  integer, parameter :: max_rows = 24, output_count = 19
  real(c_double), parameter :: missing = -1.0_c_double, no_trend = -1.0e9_c_double
contains
  ! Bounded insertion sort avoids allocation and external numerical libraries.
  pure subroutine sort_values(values, n)
    integer, intent(in) :: n
    real(c_double), intent(inout) :: values(:)
    real(c_double) :: value
    integer :: i, j
    do i = 2, n
      value = values(i)
      j = i - 1
      do while (j >= 1)
        if (values(j) <= value) exit
        values(j + 1) = values(j)
        j = j - 1
      end do
      values(j + 1) = value
    end do
  end subroutine sort_values

  ! Median pairwise slope (Theil-Sen), in units per ten seconds. A single
  ! arrival spike should affect p95, but should not manufacture a rising trend.
  pure function robust_slope(values, times, n) result(slope)
    integer, intent(in) :: n
    real(c_double), intent(in) :: values(:), times(:)
    real(c_double) :: slope, pairs(max_rows * (max_rows - 1) / 2)
    integer :: i, j, count
    slope = no_trend
    if (n < 3) return
    if (times(n) - times(1) < 10) return
    count = 0
    do i = 1, n - 1
      do j = i + 1, n
        count = count + 1
        pairs(count) = 10 * (values(j) - values(i)) / (times(j) - times(i))
      end do
    end do
    call sort_values(pairs, count)
    slope = (pairs((count + 1) / 2) + pairs((count + 2) / 2)) / 2
  end function robust_slope

  pure function robust_deviation(values, n) result(deviation)
    integer, intent(in) :: n
    real(c_double), intent(in) :: values(:)
    real(c_double) :: deviation, center, copy(max_rows), distances(max_rows), mean
    if (n <= 1) then
      deviation = 0
      return
    end if
    if (n < 5) then
      mean = sum(values(1:n)) / n
      deviation = sqrt(sum((values(1:n) - mean)**2) / n)
      return
    end if
    copy(1:n) = values(1:n)
    call sort_values(copy, n)
    center = (copy((n + 1) / 2) + copy((n + 2) / 2)) / 2
    distances(1:n) = abs(values(1:n) - center)
    call sort_values(distances, n)
    deviation = 1.4826_c_double * &
      (distances((n + 1) / 2) + distances((n + 2) / 2)) / 2
  end function robust_deviation

  pure function network_score(means, jitter_p95, eligible) result(score)
    real(c_double), intent(in) :: means(:), jitter_p95
    logical, intent(in) :: eligible(:)
    real(c_double) :: score, penalty
    score = missing
    if (count(eligible(1:5)) < 2) return
    penalty = 0
    if (eligible(1)) penalty = penalty + min(35.0_c_double, means(1) * 5)
    if (eligible(2)) penalty = penalty + min(15.0_c_double, max(0.0_c_double, jitter_p95 - 20) * 0.25_c_double)
    if (eligible(3)) penalty = penalty + min(20.0_c_double, max(0.0_c_double, means(3) - 150) * 0.04_c_double)
    if (eligible(4)) penalty = penalty + min(30.0_c_double, means(4) * 3)
    if (eligible(5)) penalty = penalty + min(15.0_c_double, max(0.0_c_double, means(5) - 80) * 0.10_c_double)
    score = max(0.0_c_double, 100 - penalty)
  end function network_score

  ! Evidence needs sustained observations. A tab suspended for a minute does
  ! not provide a minute of measured network quality when it wakes up.
  pure function observed_seconds(times, n) result(seconds)
    integer, intent(in) :: n
    real(c_double), intent(in) :: times(:)
    real(c_double) :: seconds, gap
    integer :: i
    seconds = 0
    do i = 2, n
      gap = times(i) - times(i - 1)
      if (gap <= 20) seconds = seconds + gap
    end do
  end function observed_seconds

  subroutine analyze(n, x, out) bind(C, name='pw_quality_analyze')
    integer(c_int), value :: n
    real(c_double), intent(in) :: x(9, n)
    real(c_double), intent(out) :: out(output_count)
    real(c_double) :: means(8), devs(8), stable_devs(8), slopes(8), vals(max_rows), times(max_rows), weights(max_rows)
    real(c_double) :: recent(8), jitter_p95, recent_p95, duration, measured, burst, longest, run
    real(c_double) :: weight, evidence(8), total_span, stability_penalty
    real(c_double), parameter :: maxima(9) = [300.0_c_double, 100.0_c_double, 10000.0_c_double, &
      30000.0_c_double, 100.0_c_double, 30000.0_c_double, 100000.0_c_double, 100000.0_c_double, 100.0_c_double]
    integer :: counts(8), i, j, m, first
    logical :: eligible(8), recent_eligible(8)

    out = missing
    if (n < 1 .or. n > max_rows) return
    if (any(.not. ieee_is_finite(x))) return
    ! Validate here too: the C wrapper is not the numerical routine's only
    ! possible caller. Never divide by duplicate times or accept invalid units.
    do i = 1, n
      if (any(x(:, i) > maxima)) return
      if (any(x(:, i) < 0 .and. abs(x(:, i) - missing) > 0)) return
      if (x(1, i) < 0) return
    end do
    do i = 2, n
      if (x(1, i) - x(1, i - 1) < 1) return
    end do
    means = missing
    devs = 0
    stable_devs = 0
    slopes = no_trend
    counts = 0
    evidence = 0
    eligible = .false.
    recent = missing
    recent_eligible = .false.
    jitter_p95 = missing
    recent_p95 = missing
    do j = 1, 8
      m = 0
      do i = 1, n
        if (x(j + 1, i) < 0) cycle
        m = m + 1
        vals(m) = x(j + 1, i)
        times(m) = x(1, i)
        weights(m) = 1
        ! Rates describe the previous polling interval. Weight that duration
        ! so one short poll cannot dominate several seconds of reception.
        if (j /= 2 .and. j /= 3) then
          weights(m) = 0
          if (i > 1) then
            duration = x(1, i) - x(1, max(1, i - 1))
            if (duration <= 20) weights(m) = duration
          end if
        end if
      end do
      counts(j) = m
      if (m == 0) cycle
      evidence(j) = observed_seconds(times, m)
      weight = sum(weights(1:m))
      if (weight <= 0) cycle
      means(j) = sum(vals(1:m) * weights(1:m)) / weight
      devs(j) = sqrt(sum(weights(1:m) * (vals(1:m) - means(j))**2) / weight)
      stable_devs(j) = robust_deviation(vals, m)
      eligible(j) = m >= 3 .and. evidence(j) >= 10
      if (j <= 2 .and. eligible(j)) slopes(j) = robust_slope(vals, times, m)
      if (j <= 5) then
        first = 1
        do while (first <= m)
          if (times(first) >= x(1, n) - 20) exit
          first = first + 1
        end do
        if (first <= m) then
          weight = sum(weights(first:m))
          if (weight > 0) recent(j) = sum(vals(first:m) * weights(first:m)) / weight
          recent_eligible(j) = m - first + 1 >= 3 .and. observed_seconds(times(first:m), m - first + 1) >= 10
          if (j == 2) then
            call sort_values(vals(first:m), m - first + 1)
            recent_p95 = vals(first - 1 + ceiling(0.95_c_double * (m - first + 1)))
          end if
        end if
      end if
      if (j == 2 .or. j == 3) then
        call sort_values(vals, m)
        if (j == 2) jitter_p95 = vals(ceiling(0.95_c_double * m))
        if (j == 3) out(18) = vals(ceiling(0.95_c_double * m))
      end if
    end do

    out(1) = network_score(means, jitter_p95, eligible)
    stability_penalty = 0
    if (eligible(1)) stability_penalty = stability_penalty + 3 * stable_devs(1)
    if (eligible(2)) stability_penalty = stability_penalty + 2 * stable_devs(2)
    if (eligible(1) .or. eligible(2)) out(2) = max(0.0_c_double, 100 - min(100.0_c_double, stability_penalty))
    out(3) = means(1)
    out(4) = jitter_p95
    out(5) = means(3)
    out(6) = means(4)
    out(7) = means(5)
    ! Silence changes bitrate naturally; neither rate variation lowers scores.
    if (eligible(6) .and. means(6) > 0) out(8) = 100 * devs(6) / means(6)
    out(9:10) = [slopes(2), slopes(1)]
    out(11) = means(8)
    out(12) = 100.0_c_double * sum(counts(1:5)) / (5 * n)
    out(13) = n
    out(14) = network_score(recent, recent_p95, recent_eligible)
    if (eligible(8)) out(15) = max(0.0_c_double, 100 - min(100.0_c_double, means(8) * 5))

    ! Each loss sample describes the preceding interval. Missing observations
    ! and gaps over 20 seconds break runs; they never count as good reception.
    measured = 0
    burst = 0
    longest = 0
    run = 0
    do i = 2, n
      duration = x(1, i) - x(1, max(1, i - 1))
      if (x(2, i) < 0 .or. duration > 20) then
        run = 0
        cycle
      end if
      measured = measured + duration
      if (x(2, i) >= 3) then
        run = run + duration
        burst = burst + duration
        longest = max(longest, run)
      else
        run = 0
      end if
    end do
    if (measured > 0) then
      out(16) = 100 * burst / measured
      out(17) = longest
    end if
    ! Evidence coverage, not a statistical confidence interval.
    total_span = x(1, n) - x(1, 1)
    if (total_span > 0) then
      out(19) = 100 * sum(evidence(1:5)) / (5 * total_span) * min(1.0_c_double, total_span / 30)
    else
      out(19) = 0
    end if
  end subroutine analyze
end module plainwire_quality
