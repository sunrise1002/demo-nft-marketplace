import fs from "fs";
import path from "path";

type Addresses = { [key: string]: { [key: string]: string } };

function getContracts(): Addresses {
  let _addresses: string;
  let addresses: Addresses;
  try {
    const env = process.env.NODE_ENV;
    _addresses = fs.readFileSync(
      path.join(__dirname, `../configs/${env}.contract-addresses.json`),
      "utf8"
    );
    addresses = JSON.parse(`${_addresses}`);
  } catch (err) {
    console.log("Can not get addresses: ", err);
    return {};
  }
  return addresses;
}

function saveContract(
  network: string,
  contract: string,
  address: string
): void {
  const env = process.env.NODE_ENV;

  const addresses: Addresses = getContracts();
  addresses[network] = addresses[network] || {};
  addresses[network][contract] = address;
  fs.writeFileSync(
    path.join(__dirname, `../configs/${env}.contract-addresses.json`),
    JSON.stringify(addresses, null, "    ")
  );
}

export { getContracts, saveContract };
