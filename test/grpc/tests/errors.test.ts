import { test } from "vitest";
import { status } from "@grpc/grpc-js";
import { call, connect, expectStatus } from "../src/client";

const client = connect();

// Server-minted ids are URL-safe base64; this literal can never be minted.
const GHOST_VM = "no-such-vm";

test("GetVm on an unknown vm_id is NOT_FOUND", async () => {
  await expectStatus(call(client, client.getVm, { vmId: GHOST_VM }), status.NOT_FOUND);
});

test("StopVm on an unknown vm_id is NOT_FOUND", async () => {
  await expectStatus(call(client, client.stopVm, { vmId: GHOST_VM }), status.NOT_FOUND);
});

test("GetVmUsage on a never-metered vm_id is NOT_FOUND", async () => {
  await expectStatus(call(client, client.getVmUsage, { vmId: GHOST_VM }), status.NOT_FOUND);
});

test("CreateVm with an empty img_id is INVALID_ARGUMENT", async () => {
  await expectStatus(
    call(client, client.createVm, {
      imgId: "",
      instanceType: "INSTANCE_TYPE_MICRO",
      arch: "ARCHITECTURE_X86_64",
    }),
    status.INVALID_ARGUMENT,
  );
});

// proto3 delivers unknown enum ints verbatim; only an off-BEAM client can
// produce this wire shape, which is exactly why this suite exists.
test("CreateVm with an unrecognised instance_type value is INVALID_ARGUMENT", async () => {
  await expectStatus(
    call(client, client.createVm, {
      imgId: "irrelevant",
      instanceType: 999 as never,
      arch: "ARCHITECTURE_X86_64",
    }),
    status.INVALID_ARGUMENT,
  );
});

test("CreateVm with an unrecognised arch value is INVALID_ARGUMENT", async () => {
  await expectStatus(
    call(client, client.createVm, {
      imgId: "irrelevant",
      instanceType: "INSTANCE_TYPE_MICRO",
      arch: 999 as never,
    }),
    status.INVALID_ARGUMENT,
  );
});

test("LoadImage with an empty image_ref is INVALID_ARGUMENT", async () => {
  await expectStatus(call(client, client.loadImage, { imageRef: "" }), status.INVALID_ARGUMENT);
});

test("GetHostAddress on an unknown vm_id is NOT_FOUND", async () => {
  await expectStatus(
    call(client, client.getHostAddress, { vmId: GHOST_VM }),
    status.NOT_FOUND,
  );
});

test("Exec on an unknown vm_id is NOT_FOUND", async () => {
  await expectStatus(
    call(client, client.exec, { vmId: GHOST_VM, argv: ["/bin/true"] }),
    status.NOT_FOUND,
  );
});

test("Exec with an empty vm_id is INVALID_ARGUMENT", async () => {
  await expectStatus(
    call(client, client.exec, { vmId: "", argv: ["/bin/true"] }),
    status.INVALID_ARGUMENT,
  );
});

test("Exec with an empty argv is INVALID_ARGUMENT", async () => {
  await expectStatus(
    call(client, client.exec, { vmId: GHOST_VM, argv: [] }),
    status.INVALID_ARGUMENT,
  );
});
