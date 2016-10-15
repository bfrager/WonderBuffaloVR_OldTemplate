﻿Shader "Hidden/8i/HVRShadowCollect"
{
	Properties
	{
		_oDEP("Offscreen Depth", 2D) = "" {}
		_oLSDEP("Offscreen(Light Space) Depth", 2D) = "" {}
	}
	CGINCLUDE
	#include "UnityStandardCore.cginc"

	struct ia_out
	{ 
		float4 vertex : POSITION;
	};

	struct vs_out
	{
		float4 vertex	: SV_POSITION;
		float4 spos		: TEXCOORD0;
	};


	vs_out vert(ia_out v)
	{
		vs_out o;
		o.vertex = v.vertex;
		o.spos = ComputeScreenPos(v.vertex);
		return o;
	}

	struct gbuffer_out
	{
		half4 diffuse           : SV_Target0; // RT0: diffuse color (rgb), occlusion (a)
		float depth				: SV_Depth;
	};

	uniform sampler2D _oDEP; // camera space 
	uniform sampler2D _oLSDEP; // light space
	uniform samplerCUBE  _oLSDEPCUBE; // point light only, light space

	uniform float4x4 _ViewProjectInverse;
	uniform float4x4 _LSViewProject;

	float4 _LightPosRange; 
	float4 _LightDirectionAngle;

	float4 _HVRLightShadowData;
	// no array support from command buffer in 5.3.5
	float4 _HVRShadowOffsets0;
	float4 _HVRShadowOffsets1;
	float4 _HVRShadowOffsets2;
	float4 _HVRShadowOffsets3;
	float4 _HVRMapTexelSize;

	float4 DepthToWPOS(float depth, float2 uv)
	{
		// Returns World Position of a pixel from clip-space depth map..
		//float depth = tex2D(_oDEP, uv);
		// H is the viewport position at this pixel in the range -1 to 1.

		depth = depth * 2 - 1;

#if UNITY_UV_STARTS_AT_TOP
		uv.y = 1.0 - uv.y;
#endif

		float4 H = float4((uv.x) * 2 - 1, (uv.y) * 2 - 1, depth, 1.0);
		float4 D = mul(_ViewProjectInverse, H);
		D /= D.w;

		return D;
	}

	float HVRSampleShadowmap(float4 LSPOS, float2 coord)
	{
		float atten = 1.0f;

#if defined (SHADOWS_SOFT)
		float4 LSDep;
		float4 weight;
		float4 bias = 0.0005;

		float2 MapSize = _HVRMapTexelSize.xy;
		float2 TexelSize = _HVRMapTexelSize.zw;

		float2 pixcoord = coord * MapSize.xy + float2(0.5, 0.5);
		float2 pixcoord_i = floor(pixcoord);
		pixcoord_i = pixcoord_i * TexelSize;
		
		LSDep.x = tex2D(_oLSDEP, pixcoord_i + float2(0, 0));
		LSDep.y = tex2D(_oLSDEP, pixcoord_i + float2(0, TexelSize.y));
		LSDep.z = tex2D(_oLSDEP, pixcoord_i + float2(TexelSize.x, 0));
		LSDep.w = tex2D(_oLSDEP, pixcoord_i + float2(TexelSize.x, TexelSize.y));

		float2 st = frac(pixcoord);
		
		weight.x = (1 - st.x) *(1 - st.y);
		weight.y = (1 - st.x) * st.y;
		weight.z = st.x * (1 - st.y);
		weight.w = st.x * st.y;

		float4 shadows = (LSDep + bias < LSPOS.zzzz) ? _HVRLightShadowData.r : 1.0f;
		atten = dot(shadows, weight);
#else
		// (Perhaps)since the light space shadowmap is generated by Unity itself, we don't apply Y-flip to coord
		// sample should use a coord that in LIGHT SPACE
		float bias = 0.0005;
		float LSDep = tex2D(_oLSDEP, coord);
		
		// compare LSDep(pixel depth, from light space shadowmap) and LSPOS.z(pixel depth, from current HVR Actor)
		if (LSDep + bias < LSPOS.z)
		{
			atten = _HVRLightShadowData.r;
		}
		
#endif
		return atten;
	}

	gbuffer_out frag_gbuffer_spot(vs_out v)
	{
#if UNITY_UV_STARTS_AT_TOP
		v.spos.y = 1.0 - v.spos.y;
#endif
		float dep = tex2D(_oDEP, v.spos.xy);
		
		float atten = 1.0f;
		float lighting = 1.0f;

		// get rid of other geometry not on HVR color map
		if (dep == 1)
			atten = 1.0f;
		else
		{
			half4 WPOS;
			// WPOS in world space, WPOS.z in clip space
			WPOS = DepthToWPOS(dep, v.spos.xy);

			// LSPOS, pixel position in LIGHT SPACE, should be okay
			// Calc light space depth from reconstructed world position
			float4 LSPOS = mul(_LSViewProject, WPOS);
			LSPOS /= LSPOS.w; // perspective divide

#if defined(SHADER_API_GLCORE) || defined(SHADER_API_OPENGL) || defined(SHADER_API_GLES) || defined(SHADER_API_GLES3)
			LSPOS.z = (LSPOS.z + 1.0) * 0.5;
#endif

			float2 coord = LSPOS.xy;
			// convert from [-1, 1] to [0, 1]
			coord += 1.0f;
			coord *= 0.5f;

			atten = HVRSampleShadowmap(LSPOS, coord);

			// inner circle radius = 0.5
			// outter circle radius = 1.0
			lighting = lerp(1, _HVRLightShadowData.r, 
				saturate((sqrt(dot(LSPOS.xy, LSPOS.xy)) - 0.5) / (1.0 - 0.5))); // need to do saturate here otherwise lerp will exceeds [1, _HVRLightShadowData.r]
		}

		// because we're not doing additive lighting, we choose the darkest color
		atten = min(atten, lighting);

		gbuffer_out o;
		o.diffuse = float4(atten, atten, atten, 1);
		o.depth = dep;

		return o;
	}

	gbuffer_out frag_gbuffer_directional(vs_out v)
	{
#if UNITY_UV_STARTS_AT_TOP
		v.spos.y = 1.0 - v.spos.y;
#endif
		float dep = tex2D(_oDEP, v.spos.xy);
		float atten = 1.0f;

		// get rid of other geometry not on HVR color map
		if (dep == 1)
			atten = 1.0f;
		else
		{
			half4 WPOS;
			// WPOS in world space, WPOS.z in clip space
			WPOS = DepthToWPOS(dep, v.spos.xy);

			// LSPOS, pixel position in LIGHT SPACE, should be okay
			// Calc light space depth from reconstructed world position
			float4 LSPOS = mul(_LSViewProject, WPOS);
			LSPOS /= LSPOS.w; // perspective divide

#if defined(SHADER_API_GLCORE) || defined(SHADER_API_OPENGL) || defined(SHADER_API_GLES) || defined(SHADER_API_GLES3)
			LSPOS.z = (LSPOS.z + 1.0) * 0.5;
#endif
			float2 coord = LSPOS.xy;
			// convert from [-1, 1] to [0, 1]
			coord += 1.0f;
			coord *= 0.5f;

			if (coord.x < 0 || coord.x > 1 ||
				coord.y < 0 || coord.y > 1)
			{
				atten = 1.0f;
			}
			else
			{
				atten = HVRSampleShadowmap(LSPOS, coord);
			}
		}

		gbuffer_out o;

		o.diffuse = float4(atten, atten, atten, 1);
		o.depth = dep;

		return o;
	}

	inline float HVRSampleCubeDistance(float3 vec)
	{
		return UnityDecodeCubeShadowDepth(texCUBE(_oLSDEPCUBE, vec));
	}
	inline float HVRSampleCubeShadowmap(float3 vec)
	{
		float mydist = length(vec) * _LightPosRange.w;
		mydist *= 0.97; // bias

#if defined (SHADOWS_SOFT)
		float z = 1.0 / 128.0;
		float4 shadowVals;
		shadowVals.x = HVRSampleCubeDistance(vec + float3(z, z, z));
		shadowVals.y = HVRSampleCubeDistance(vec + float3(-z, -z, z));
		shadowVals.z = HVRSampleCubeDistance(vec + float3(-z, z, -z));
		shadowVals.w = HVRSampleCubeDistance(vec + float3(z, -z, -z));
		float4 shadows = (shadowVals < mydist.xxxx) ? _HVRLightShadowData.rrrr : 1.0f;
		return dot(shadows, 0.25);
#else
		float dist = HVRSampleCubeDistance(vec);
		return dist < mydist ? _HVRLightShadowData.r : 1.0;
#endif
	}

	gbuffer_out frag_gbuffer_point(vs_out v)
	{
#if UNITY_UV_STARTS_AT_TOP
		v.spos.y = 1.0 - v.spos.y;
#endif

		float dep = tex2D(_oDEP, v.spos.xy);
		float atten = 1.0f;

		// get rid of other geometry not on HVR color map
		if (dep == 1)
			atten = 1.0f;
		else
		{
			half4 WPOS;
			// WPOS in world space
			WPOS = DepthToWPOS(dep, v.spos.xy);

			float3 vec = WPOS - _LightPosRange.xyz;
			atten = HVRSampleCubeShadowmap(vec);
		}

		gbuffer_out o;

		o.diffuse = float4(atten, atten, atten, 1);
		o.depth = dep;

		return o;

	}

	ENDCG

	SubShader
	{
		Fog{ Mode Off }					// no fog in g-buffers pass
		Cull Off							// Render both front and back facing polygons.
		ZTest Less      					// Renders without drawing over the skybox
		//ZWrite On							// Default is on
		//Lighting Off

		Pass
		{
			Name "HVR Forward Shadow Collector Spot"

			Blend DstColor Zero

			CGPROGRAM
			#pragma target 3.0
			#pragma vertex vert
			#pragma fragment frag_gbuffer_spot 
			#pragma multi_compile ___ SHADOWS_SOFT
			ENDCG
		}

		Pass
		{
			Name "HVR Forward Shadow Collector Directional"

			Blend DstColor Zero

			CGPROGRAM
			#pragma target 3.0
			#pragma vertex vert
			#pragma fragment frag_gbuffer_directional
			#pragma multi_compile ___ SHADOWS_SOFT
			ENDCG
		} 

		Pass
		{
			Name "HVR Forward Shadow Collector Point"

			Blend DstColor Zero

			CGPROGRAM
			#pragma target 3.0
			#pragma vertex vert
			#pragma fragment frag_gbuffer_point
			#pragma multi_compile ___ SHADOWS_SOFT
			ENDCG

		}
	}
	Fallback "Diffuse"
}
