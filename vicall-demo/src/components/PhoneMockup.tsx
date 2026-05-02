import React, {CSSProperties, ReactNode} from 'react';
import {AbsoluteFill, Img, OffthreadVideo} from 'remotion';
import {hasStaticAsset, staticAsset} from '../lib/static';

export const PhoneMockup: React.FC<{
	videoSrc?: string;
	imageSrc?: string;
	glowColor?: string;
	glowIntensity?: number;
	glassOverlayOpacity?: number;
	angledReflectionOpacity?: number;
	topReflectionOpacity?: number;
	placeholderTitle?: string;
	placeholderBody?: string;
	children?: ReactNode;
	scale?: number;
	shadowStrength?: number;
	screenTint?: string;
	style?: CSSProperties;
}> = ({
	videoSrc,
	imageSrc,
	glowColor = 'rgba(77,124,255,0.18)',
	glowIntensity = 0.18,
	glassOverlayOpacity = 0.56,
	angledReflectionOpacity = 0.3,
	topReflectionOpacity = 0.36,
	placeholderTitle,
	placeholderBody,
	children,
	scale = 1,
	shadowStrength = 1,
	screenTint,
	style,
}) => {
	const asset = videoSrc ? staticAsset(videoSrc) : null;
	const hasVideo = Boolean(asset && hasStaticAsset(videoSrc!));
	const imageAsset = imageSrc ? staticAsset(imageSrc) : null;
	const hasImage = Boolean(imageAsset && hasStaticAsset(imageSrc!));
	const deviceDepth = 10 * scale;
	const shellBorder = `${2.2 * scale}px solid rgba(118,121,130,0.62)`;
	const shellShadow = `0 ${10 * shadowStrength * scale}px ${20 * shadowStrength * scale}px rgba(7,17,38,0.10), 0 ${28 * shadowStrength * scale}px ${58 * shadowStrength * scale}px rgba(7,17,38,0.16), 0 ${72 * shadowStrength * scale}px ${120 * shadowStrength * scale}px rgba(7,17,38,0.09), 0 0 ${72 * glowIntensity * scale}px ${18 * glowIntensity * scale}px ${glowColor}`;

	return (
		<div
			style={{
				position: 'relative',
				width: 300 * scale,
				height: 632 * scale,
				borderRadius: 54 * scale,
				padding: 9 * scale,
				background:
					'linear-gradient(180deg, rgba(114,118,126,0.98) 0%, rgba(62,64,73,1) 12%, rgba(23,24,30,1) 42%, rgba(8,8,12,1) 100%)',
				border: shellBorder,
				boxShadow: shellShadow,
				overflow: 'visible',
				transformStyle: 'preserve-3d',
				...style,
			}}
		>
			<div
				style={{
					position: 'absolute',
					inset: 5 * scale,
					borderRadius: 50 * scale,
					background:
						'linear-gradient(180deg, rgba(72,75,84,0.94) 0%, rgba(24,25,31,0.98) 34%, rgba(8,9,12,1) 100%)',
					border: `${1.4 * scale}px solid rgba(255,255,255,0.05)`,
					transform: `translateZ(${-deviceDepth}px) scale(0.994)`,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 34 * scale,
					bottom: 34 * scale,
					right: -1 * scale,
					width: 12 * scale,
					borderRadius: 999 * scale,
					background:
						'linear-gradient(180deg, rgba(136,139,146,0.96) 0%, rgba(80,83,91,0.97) 24%, rgba(27,27,33,1) 66%, rgba(10,10,14,1) 100%)',
					transform: `translateZ(${-deviceDepth * 0.55}px) rotateY(90deg)`,
					transformOrigin: 'left center',
					opacity: 0.92,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 34 * scale,
					bottom: 34 * scale,
					left: -1 * scale,
					width: 10 * scale,
					borderRadius: 999 * scale,
					background:
						'linear-gradient(180deg, rgba(116,118,126,0.82) 0%, rgba(60,62,69,0.94) 28%, rgba(21,21,28,1) 74%, rgba(9,9,12,1) 100%)',
					transform: `translateZ(${-deviceDepth * 0.5}px) rotateY(-90deg)`,
					transformOrigin: 'right center',
					opacity: 0.8,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: 40 * scale,
					right: 40 * scale,
					bottom: -1 * scale,
					height: 10 * scale,
					borderRadius: 999 * scale,
					background:
						'linear-gradient(90deg, rgba(42,44,50,0.95) 0%, rgba(20,20,27,1) 22%, rgba(8,8,11,1) 50%, rgba(20,20,27,1) 78%, rgba(42,44,50,0.95) 100%)',
					transform: `translateZ(${-deviceDepth * 0.55}px) rotateX(90deg)`,
					transformOrigin: 'center top',
					opacity: 0.95,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: '11%',
					right: '11%',
					bottom: -22 * scale,
					height: 52 * scale,
					borderRadius: '50%',
					background:
						'radial-gradient(circle, rgba(15,21,34,0.18) 0%, rgba(15,21,34,0.10) 52%, rgba(15,21,34,0) 82%)',
					filter: `blur(${20 * shadowStrength * scale}px)`,
					opacity: Math.min(1, 0.66 + shadowStrength * 0.06),
					pointerEvents: 'none',
					transform: `translateZ(${-20 * scale}px)`,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: '16%',
					right: '16%',
					bottom: -34 * scale,
					height: 70 * scale,
					borderRadius: '50%',
					background:
						'radial-gradient(circle, rgba(8,12,20,0.12) 0%, rgba(8,12,20,0.05) 56%, rgba(8,12,20,0) 84%)',
					filter: `blur(${28 * shadowStrength * scale}px)`,
					opacity: Math.min(1, 0.56 + shadowStrength * 0.04),
					pointerEvents: 'none',
					transform: `translateZ(${-26 * scale}px)`,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					inset: -16 * scale,
					borderRadius: 72 * scale,
					background: `radial-gradient(circle at 50% 50%, ${glowColor} 0%, rgba(255,255,255,0) 68%)`,
					filter: `blur(${30 * scale}px)`,
					opacity: Math.min(0.44, glowIntensity * 1.35),
					pointerEvents: 'none',
					transform: `translateZ(${-12 * scale}px)`,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					inset: 2 * scale,
					borderRadius: 50 * scale,
					border: `${1.5 * scale}px solid rgba(255,255,255,0.12)`,
					boxShadow: `inset 0 ${1.5 * scale}px ${5 * scale}px rgba(255,255,255,0.12), inset 0 ${-8 * scale}px ${18 * scale}px rgba(0,0,0,0.34)`,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 18 * scale,
					left: 26 * scale,
					width: 120 * scale,
					height: 120 * scale,
					borderRadius: '50%',
					background: 'radial-gradient(circle at center, rgba(255,255,255,0.18), rgba(255,255,255,0))',
					filter: `blur(${26 * scale}px)`,
					opacity: 0.56,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					right: 22 * scale,
					top: 90 * scale,
					width: 78 * scale,
					height: 440 * scale,
					borderRadius: 999 * scale,
					background:
						'linear-gradient(180deg, rgba(255,255,255,0.18) 0%, rgba(255,255,255,0.06) 22%, rgba(255,255,255,0.0) 60%)',
					filter: `blur(${16 * scale}px)`,
					opacity: 0.5,
					pointerEvents: 'none',
					transform: `translateZ(${18 * scale}px) rotate(7deg)`,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: 10 * scale,
					top: 26 * scale,
					bottom: 26 * scale,
					width: 10 * scale,
					borderRadius: 999 * scale,
					background:
						'linear-gradient(180deg, rgba(255,255,255,0.18) 0%, rgba(255,255,255,0.07) 28%, rgba(255,255,255,0.02) 72%, rgba(255,255,255,0.08) 100%)',
					filter: `blur(${5 * scale}px)`,
					opacity: 0.42,
					pointerEvents: 'none',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 12 * scale,
					left: '50%',
					transform: 'translateX(-50%)',
					width: 126 * scale,
					height: 35 * scale,
					borderRadius: 20 * scale,
					background: 'linear-gradient(180deg, #0b0b0d 0%, #020203 100%)',
					border: `${0.8 * scale}px solid rgba(255,255,255,0.04)`,
					boxShadow: `0 ${1.5 * scale}px ${4 * scale}px rgba(0,0,0,0.18), inset 0 1px ${1.2 * scale}px rgba(255,255,255,0.05)`,
					opacity: 0.82,
					zIndex: 2,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 25 * scale,
					left: '50%',
					transform: 'translateX(-58%)',
					width: 46 * scale,
					height: 5 * scale,
					borderRadius: 999 * scale,
					background: 'rgba(255,255,255,0.10)',
					zIndex: 4,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 22 * scale,
					left: '50%',
					transform: `translateX(${28 * scale}px)`,
					width: 10.5 * scale,
					height: 10.5 * scale,
					borderRadius: '50%',
					background:
						'radial-gradient(circle at 35% 35%, rgba(77,124,255,0.28) 0%, rgba(22,32,58,0.42) 28%, rgba(4,4,6,1) 72%)',
					boxShadow: `inset 0 0 ${1.4 * scale}px rgba(255,255,255,0.08), 0 0 ${1.2 * scale}px rgba(0,0,0,0.35)`,
					zIndex: 5,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					top: 25 * scale,
					left: '50%',
					transform: `translateX(${16 * scale}px)`,
					width: 4 * scale,
					height: 4 * scale,
					borderRadius: '50%',
					background: 'rgba(255,255,255,0.09)',
					opacity: 0.7,
					zIndex: 5,
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: -3.5 * scale,
					top: 132 * scale,
					width: 4 * scale,
					height: 56 * scale,
					borderRadius: 4 * scale,
					background: '#44454d',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					left: -3.5 * scale,
					top: 202 * scale,
					width: 4 * scale,
					height: 92 * scale,
					borderRadius: 4 * scale,
					background: '#44454d',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					right: -3.5 * scale,
					top: 160 * scale,
					width: 4 * scale,
					height: 112 * scale,
					borderRadius: 4 * scale,
					background: '#44454d',
				}}
			/>
			<div
				style={{
					position: 'absolute',
					inset: 9 * scale,
					borderRadius: 45 * scale,
					overflow: 'hidden',
					background: '#000',
					boxShadow: `0 ${5 * scale}px ${16 * scale}px rgba(0,0,0,0.24), inset 0 0 0 ${1 * scale}px rgba(255,255,255,0.06), inset 0 ${-14 * scale}px ${24 * scale}px rgba(0,0,0,0.28)`,
					transform: `translateZ(${2.5 * scale}px)`,
				}}
			>
				<div
					style={{
						position: 'absolute',
						top: 7 * scale,
						left: '50%',
						transform: 'translateX(-50%)',
						width: 122 * scale,
						height: 33 * scale,
						borderRadius: 18 * scale,
						background: 'linear-gradient(180deg, #050506 0%, #010102 100%)',
						boxShadow: `0 ${1.5 * scale}px ${4 * scale}px rgba(0,0,0,0.22), inset 0 1px ${1.1 * scale}px rgba(255,255,255,0.04)`,
						zIndex: 8,
						pointerEvents: 'none',
					}}
				/>
				<div
					style={{
						position: 'absolute',
						top: 19 * scale,
						left: '50%',
						transform: 'translateX(-63%)',
						width: 42 * scale,
						height: 4.5 * scale,
						borderRadius: 999 * scale,
						background: 'rgba(255,255,255,0.12)',
						zIndex: 9,
						pointerEvents: 'none',
					}}
				/>
				<div
					style={{
						position: 'absolute',
						top: 15 * scale,
						left: '50%',
						transform: `translateX(${27 * scale}px)`,
						width: 10 * scale,
						height: 10 * scale,
						borderRadius: '50%',
						background:
							'radial-gradient(circle at 35% 35%, rgba(96,146,255,0.34) 0%, rgba(22,32,58,0.44) 28%, rgba(4,4,6,1) 72%)',
						boxShadow: `inset 0 0 ${1.4 * scale}px rgba(255,255,255,0.08), 0 0 ${1.2 * scale}px rgba(0,0,0,0.35)`,
						zIndex: 9,
						pointerEvents: 'none',
					}}
				/>
				<div
					style={{
						position: 'absolute',
						top: 18.5 * scale,
						left: '50%',
						transform: `translateX(${15 * scale}px)`,
						width: 3.8 * scale,
						height: 3.8 * scale,
						borderRadius: '50%',
						background: 'rgba(255,255,255,0.11)',
						opacity: 0.72,
						zIndex: 9,
						pointerEvents: 'none',
					}}
				/>
				{hasVideo && asset ? (
					<OffthreadVideo
						src={asset}
						style={{
							width: '100%',
							height: '100%',
							objectFit: 'cover',
							objectPosition: 'center center',
						}}
					/>
				) : hasImage && imageAsset ? (
					<Img
						src={imageAsset}
						style={{
							width: '100%',
							height: '100%',
							objectFit: 'cover',
							objectPosition: 'center center',
						}}
					/>
				) : children ? (
					<AbsoluteFill>{children}</AbsoluteFill>
				) : (
					<div
						style={{
							width: '100%',
							height: '100%',
							display: 'flex',
							flexDirection: 'column',
							alignItems: 'center',
							justifyContent: 'center',
							padding: 28 * scale,
							background:
								'linear-gradient(180deg, rgba(18,18,26,1), rgba(8,8,14,1))',
							color: '#f0f0f5',
							textAlign: 'center',
							fontFamily: 'Montserrat, sans-serif',
						}}
					>
						<div
							style={{
								fontSize: 24 * scale,
								fontWeight: 800,
								marginBottom: 12 * scale,
							}}
						>
							{placeholderTitle ?? 'Awaiting Clip'}
						</div>
						<div
							style={{
								fontSize: 15 * scale,
								lineHeight: 1.5,
								color: 'rgba(240,240,245,0.72)',
							}}
						>
							{placeholderBody ?? (videoSrc ? `Add ${videoSrc} to public/ when ready.` : 'Screen content goes here.')}
						</div>
					</div>
				)}
				<div
					style={{
						position: 'absolute',
						inset: 0,
						background:
							'linear-gradient(180deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0.03) 14%, rgba(255,255,255,0) 34%, rgba(255,255,255,0.02) 76%, rgba(255,255,255,0.05) 100%)',
						pointerEvents: 'none',
						mixBlendMode: 'screen',
						opacity: glassOverlayOpacity,
					}}
				/>
				<div
					style={{
						position: 'absolute',
						left: '-8%',
						top: '-2%',
						width: '56%',
						height: '48%',
						background:
							'linear-gradient(132deg, rgba(255,255,255,0.20) 0%, rgba(255,255,255,0.06) 34%, rgba(255,255,255,0) 58%)',
						filter: `blur(${18 * scale}px)`,
						opacity: angledReflectionOpacity,
						pointerEvents: 'none',
						transform: 'rotate(-8deg)',
					}}
				/>
				<div
					style={{
						position: 'absolute',
						left: 16 * scale,
						right: 16 * scale,
						top: 16 * scale,
						height: 140 * scale,
						borderRadius: 40 * scale,
						background:
							'linear-gradient(180deg, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0.05) 28%, rgba(255,255,255,0) 100%)',
						filter: `blur(${10 * scale}px)`,
						opacity: topReflectionOpacity,
						pointerEvents: 'none',
					}}
				/>
				{screenTint ? (
					<div
						style={{
							position: 'absolute',
							inset: 0,
							background: screenTint,
							pointerEvents: 'none',
						}}
					/>
				) : null}
			</div>
		</div>
	);
};
