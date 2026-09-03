{
  monstar,
  system,
}:
(monstar.packages.${system}.default.overrideAttrs (old: {
  meta = (old.meta or { }) // {
    mainProgram = "monstar";
  };
  passthru = (old.passthru or { }) // {
    windowClass = "dev.rockorager.monstar";
  };
}))
