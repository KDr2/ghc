test('T21370',
  [ extra_files(["subdir", "test.cmm", "test2.cmm", "Main.hs"])
  , req_cmm
  ], makefile_test, [])
