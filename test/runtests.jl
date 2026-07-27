using TestItemRunner

@testitem "Aqua.jl" begin
    import Aqua
    import ManyUIWeb
    Aqua.test_all(ManyUIWeb; piracies=false)
end

@run_package_tests
