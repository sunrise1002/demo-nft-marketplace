// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
 
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract MockERC721 is Initializable, ERC721Upgradeable, AccessControlUpgradeable {

    function initialize () public initializer {
        __ERC721_init("Collection", "COL");
        __AccessControl_init_unchained();
        // set admin role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    event NFTCreated(
        address owner,
        uint256 tokenId
    );

    uint256 public counter;

    function mintToken(address _owner) public {
        _mint(_owner, counter);

        counter++;

        emit NFTCreated(_owner, counter - 1);
    }

    function mintTokenById(address _owner, uint256 _tokenId) public {
        _mint(_owner, _tokenId);

        counter++;

        emit NFTCreated(_owner, _tokenId);
    }
}