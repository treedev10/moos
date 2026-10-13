# primes.ms - print the prime numbers below 60
set n = 2
while n < 60
  set d = 2
  set prime = 1
  while d * d <= n
    if n % d == 0
      set prime = 0
    end
    set d = d + 1
  end
  if prime
    print n
  end
  set n = n + 1
end
