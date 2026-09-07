{
  inputs,
  system,
}:
let
  coldC = inputs.self.packages.${system}.c;
in
(coldC.withCache { packages.${system}.c.incremental = coldC.incremental; }).overrideAttrs (old: {
  postInstall = old.postInstall + ''
    pct=$(cat $incremental/ccache-hit-pct)
    echo "self-test[c]: $pct% ccache hits restoring an unchanged build"
    if [ "$pct" -lt 90 ]; then
      echo "self-test[c]: FAILED — expected near-total hits" >&2
      exit 1
    fi
  '';
})
