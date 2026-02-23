{
  description = "Pangea Kubernetes — cloud-agnostic Kubernetes abstractions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ruby-nix.url = "github:inscapist/ruby-nix";
    flake-utils.url = "github:numtide/flake-utils";
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    forge = {
      url = "github:pleme-io/forge";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.substrate.follows = "substrate";
    };
  };

  outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, ... }:
    (import "${substrate}/lib/ruby-gem-flake.nix" {
      inherit nixpkgs ruby-nix flake-utils substrate forge;
    }) {
      inherit self;
      name = "pangea-kubernetes";
    };
}
