import Flux
import Testing
import Weave

@Test
func test_bootstrap_releasedFlux_collectsFiniteStream() async {
    let values = await Flux.from([1, 2, 3]).collect()
    #expect(values == [1, 2, 3])
}
