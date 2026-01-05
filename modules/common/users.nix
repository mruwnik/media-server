{ config, lib, pkgs, ... }:

{
  # Main user
  users.users.dan = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN/7ZMH3Q2QQQFD6Ugtv8Lii2WTdYV3GM0aYa5Bu+Bvw me@ahiru.pl"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDYK1pFIEr2bfNt7Ws7DIz05xnNXP5lPxc+dbN0+WPesyZRTcz9AuDq7d6uG/hcSk9qKKlZ6rImz9+g2EQSswTB3D08kaCsky3cXi3RHfWfzAmDJBBRpC8ZnZZypVaaXWEzNAx2g6JvHDRUfyDzUcRlrVoWnyveIzz+o/R52mdenC0+ynNwAs/an4V6mblrSwHQPbZJhFWnA5A53bkc3znGl7JTkQkq2rSr4WQymbhe/ZyND9/CIFoOXTuvKfuNu7YQ70qjLBmaKZMxAY+XTzPAnzziOW9AIZaWRf6ddufIq7+7VOm/f6nYOjDVQGgsUAkOuENUHyjjSfNO2FH98C9PnyQtic84Y7HFD0K+saPTck1+sFSSpHdXzo0AWRPGwtz1zvAEBqJorY6Cesw4iBcn2Z+JR3OA8We3Pi4EmPuYb9jn4uGYMKYKL+o+yVEhfjh47MY2cNSiSaQB1hfr/PvpQOinVohM/xkjPuoxEEXe1KHNoq+NOgD5SPfpzjpw0TkR52gDNO8fN3MkAB+tsna8B6cn1uB0+FV6kK8BdLKwDA6oVCZDYZDiuGlPLj3Q+Hdq3wCreuPjCxzhwehB41qKDv1KFQycQJQv9wbeUJbxLtZXJ4Iu1kI45Ui3D2agFMT3CrGepUOMLaztI3gbE5lxgBvGPxhExaioe0ciRSB7eQ== tojad99@gmail.com"
    ];
  };

  # Additional users for Samba access
  users.users.nadia = {
    isNormalUser = true;
    uid = 1002;
    description = "Nadia";
  };

  users.users.rumun = {
    isNormalUser = true;
    uid = 1003;
    description = "Rumun";
  };

  # Passwordless sudo for wheel
  security.sudo.wheelNeedsPassword = false;

  # Service users will be added by their respective modules:
  # - calibre (calibre-web)
  # - torrents (rtorrent)
  # - radicale
  # - forgejo creates its own
  # - cryptpad creates its own
}
