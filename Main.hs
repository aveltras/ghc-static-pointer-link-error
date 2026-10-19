import Repro (build)

main :: IO ()
main = build `seq` pure ()
