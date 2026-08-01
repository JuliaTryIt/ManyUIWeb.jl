# tachikoma_ext_tests.jl -- the Tachikoma frontend's stub contract.
#
# The extension itself needs Tachikoma with the `io=` sink (PR #39), which
# this package's test environment does not carry, so the end-to-end
# round-trip is exercised by examples/tachikoma_web.jl against a patched
# Tachikoma, not here. What CI CAN pin, and does, is the promise the main
# package makes WITHOUT the extension: that `serve_tachikoma` exists, is
# exported, and fails with a sentence rather than a `MethodError` when
# Tachikoma is absent.

@testitem "tachikoma: serve_tachikoma is exported and stubbed" begin
    using ManyUIWeb, ManyUITUI

    @test isdefined(ManyUIWeb, :serve_tachikoma)
    @test :serve_tachikoma in names(ManyUIWeb)
    # With no Tachikoma loaded the stub answers, and it names the fix.
    err = try
        serve_tachikoma(() -> nothing)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("Tachikoma", err.msg)
end
