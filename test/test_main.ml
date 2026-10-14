let () =
  Alcotest.run "analyser"
    [ ("inference_client", Test_inference_client.tests) ]
