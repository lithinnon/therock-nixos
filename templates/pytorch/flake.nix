{
  # ROCm torch on the shared TheRock (therock-nixos). Nothing here names a GPU:
  # each machine picks its own when a command runs (`nix develop`, direnv).
  inputs.therock.url = "github:lithinnon/therock-nixos";
  outputs = { therock, ... }: therock.lib.pytorchProject { src = ./.; };
}
