# Avalanche L1 Middleware

## Suzaku Adaptation

- [ ] Use a struct to store subnetworks information, instead of the Subnetwork library that uses bytes shifting to store in a single storage slot.
- [ ] Create a `IAvalancheL1Middleware` interface and move all errors and structs to the interface.
- [ ] Allow to register multiple keys for the same operator.
- [ ] Allow to track the stake of an operator for each subnetwork.
- [ ] Add prerequisites for each subnetwork to spin up a new validator.
