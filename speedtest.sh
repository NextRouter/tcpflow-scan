for HOST in ubuntu-test-0 ubuntu-test-1 ubuntu-test-2; do
  echo "Executing on $HOST..."
  ssh -n "$HOST" '~/.bun/bin/bunx speed-cloudflare-cli' &
done

wait

echo "All parallel operations completed."
