use std::{mem::size_of, sync::Arc};

use slingshot::{
    ash::vk,
    backend::{
        buffer::{Buffer, BufferDesc},
        device,
        image::*,
        shader::*,
        RenderBackend,
    },
    rg::{self, BindRgRef, Resource},
    vk_sync::AccessType,
};

use crate::temporal::*;

pub struct SurfelGiRenderer {
    surfel_meta_buf: Temporal<Buffer>,
    surfel_hash_key_buf: Temporal<Buffer>,
    surfel_hash_value_buf: Temporal<Buffer>,

    cell_index_offset_buf: Temporal<Buffer>,
    surfel_index_buf: Temporal<Buffer>,

    surfel_spatial_buf: Temporal<Buffer>,
}

const MAX_SURFEL_CELLS: usize = 1024 * 1024;
const MAX_SURFELS: usize = MAX_SURFEL_CELLS;
const MAX_SURFELS_PER_CELL: usize = 8;

macro_rules! impl_renderer_temporal_logic {
    ($($res_name:ident,)*) => {
        pub fn begin(&mut self, rg: &mut rg::RenderGraph) -> SurfelGiRenderInstance {
            SurfelGiRenderInstance {
                $(
                    $res_name: rg.import_temporal(&mut self.$res_name),
                )*
            }
        }
        pub fn end(&mut self, rg: &mut rg::RenderGraph, inst: SurfelGiRenderInstance) {
            $(
                rg.export_temporal(inst.$res_name, &mut self.$res_name);
            )*
        }

        pub fn retire(&mut self, rg: &rg::RetiredRenderGraph) {
            $(
                rg.retire_temporal(&mut self.$res_name);
            )*
        }
    };
}

fn new_temporal_storage_buffer(device: &device::Device, size_bytes: usize) -> Temporal<Buffer> {
    Temporal::new(Arc::new(
        device
            .create_buffer(
                BufferDesc::new(size_bytes, vk::BufferUsageFlags::STORAGE_BUFFER),
                None,
            )
            .unwrap(),
    ))
}

impl SurfelGiRenderer {
    pub fn new(device: &device::Device) -> Self {
        Self {
            surfel_meta_buf: new_temporal_storage_buffer(device, size_of::<u32>()),
            surfel_hash_key_buf: new_temporal_storage_buffer(
                device,
                size_of::<u32>() * MAX_SURFEL_CELLS,
            ),
            surfel_hash_value_buf: new_temporal_storage_buffer(
                device,
                size_of::<u32>() * MAX_SURFEL_CELLS,
            ),
            cell_index_offset_buf: new_temporal_storage_buffer(
                device,
                size_of::<u32>() * MAX_SURFEL_CELLS,
            ),
            surfel_index_buf: new_temporal_storage_buffer(
                device,
                size_of::<u32>() * MAX_SURFEL_CELLS * MAX_SURFELS_PER_CELL,
            ),
            surfel_spatial_buf: new_temporal_storage_buffer(device, 16 * MAX_SURFELS),
        }
    }

    impl_renderer_temporal_logic! {
        surfel_meta_buf,
        surfel_hash_key_buf,
        surfel_hash_value_buf,
        cell_index_offset_buf,
        surfel_index_buf,
        surfel_spatial_buf,
    }
}

pub struct SurfelGiRenderInstance {
    pub surfel_meta_buf: rg::Handle<Buffer>,
    pub surfel_hash_key_buf: rg::Handle<Buffer>,
    pub surfel_hash_value_buf: rg::Handle<Buffer>,

    pub cell_index_offset_buf: rg::Handle<Buffer>,
    pub surfel_index_buf: rg::Handle<Buffer>,

    pub surfel_spatial_buf: rg::Handle<Buffer>,
}

impl SurfelGiRenderInstance {
    pub fn allocate_surfels(
        &mut self,
        rg: &mut rg::RenderGraph,
        gbuffer: &rg::Handle<Image>,
        depth: &rg::Handle<Image>,
    ) -> rg::Handle<Image> {
        let mut pass = rg.add_pass();
        let mut debug_out = pass.create(&gbuffer.desc().format(vk::Format::R32G32B32A32_SFLOAT));

        SimpleComputePass::new(pass, "/assets/shaders/surfel_gi/allocate_surfels.hlsl")
            .read(&gbuffer)
            .read_aspect(depth, vk::ImageAspectFlags::DEPTH)
            .write(&mut self.surfel_meta_buf)
            .write(&mut self.surfel_hash_key_buf)
            .write(&mut self.surfel_hash_value_buf)
            .read(&self.cell_index_offset_buf)
            .read(&self.surfel_index_buf)
            .read(&self.surfel_spatial_buf)
            .write(&mut debug_out)
            .dispatch(gbuffer.desc().extent);

        debug_out
    }
}

struct SimpleComputePass<'rg> {
    pass: rg::PassBuilder<'rg>,
    pipeline: rg::RgComputePipelineHandle,
    bindings: Vec<rg::RenderPassBinding>,
}

impl<'rg> SimpleComputePass<'rg> {
    pub fn new(mut pass: rg::PassBuilder<'rg>, pipeline_path: &str) -> Self {
        let pipeline = pass.register_compute_pipeline(pipeline_path);

        Self {
            pass,
            pipeline,
            bindings: Vec::new(),
        }
    }

    pub fn read<Res>(mut self, handle: &rg::Handle<Res>) -> Self
    where
        Res: Resource + 'static,
        rg::Ref<Res, rg::GpuSrv>: rg::BindRgRef,
    {
        let handle_ref = self.pass.read(
            handle,
            AccessType::ComputeShaderReadSampledImageOrUniformTexelBuffer,
        );

        self.bindings.push(rg::BindRgRef::bind(&handle_ref));

        self
    }

    pub fn read_aspect(
        mut self,
        handle: &rg::Handle<Image>,
        aspect_mask: vk::ImageAspectFlags,
    ) -> Self {
        let handle_ref = self.pass.read(
            handle,
            AccessType::ComputeShaderReadSampledImageOrUniformTexelBuffer,
        );

        self.bindings
            .push(handle_ref.bind_view(ImageViewDescBuilder::default().aspect_mask(aspect_mask)));

        self
    }

    pub fn write<Res>(mut self, handle: &mut rg::Handle<Res>) -> Self
    where
        Res: Resource + 'static,
        rg::Ref<Res, rg::GpuUav>: rg::BindRgRef,
    {
        let handle_ref = self.pass.write(handle, AccessType::ComputeShaderWrite);

        self.bindings.push(rg::BindRgRef::bind(&handle_ref));

        self
    }

    pub fn dispatch(mut self, extent: [u32; 3]) {
        let pipeline = self.pipeline;
        let bindings = self.bindings;

        self.pass.render(move |api| {
            let pipeline =
                api.bind_compute_pipeline(pipeline.into_binding().descriptor_set(0, &bindings));

            pipeline.dispatch(extent);
        });
    }
}
